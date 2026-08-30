package com.keynumber.folino.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntSize
import com.keynumber.folino.editor.EditUiState
import com.keynumber.folino.editor.caretRectMm
import com.keynumber.folino.editor.editingHitTestForTap
import com.keynumber.folino.reader.editing.EDIT_CALLOUT_MINIMUM_WIDTH_MM
import com.keynumber.folino.reader.editing.EDIT_CARET_MINIMUM_WIDTH_MM
import com.keynumber.folino.reader.editing.EditingCallout
import com.keynumber.folino.reader.editing.EditingCaretOverlay
import com.keynumber.folino.reader.ink.AnnotationLayers
import com.keynumber.folino.reader.ink.AnnotationSurfaceState
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.EditCaretFrame
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.serialization.DecodedFrameCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreItemIDCodec
import io.github.jiyimeta.sheetmusic.compose.cursor.LoopHighlightOverlay
import io.github.jiyimeta.sheetmusic.compose.cursor.PlaybackCursorOverlay
import io.github.jiyimeta.sheetmusic.compose.draw.model.EncodablePage
import io.github.jiyimeta.sheetmusic.compose.render.FontProvider
import io.github.jiyimeta.sheetmusic.compose.render.ScorePage
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.launch

/** A4 page width (mm), used only as a pre-measurement fallback seed (page mode now reflows to the viewport). */
private const val PAGE_WIDTH_MM = 210.0

// `internal`, like its sibling [HorizontalScore]: only ReaderScreen (same module) composes it, and its
// annotation bundle is module-internal.
@Composable
internal fun PagedScore(
    state: ReaderState.Ready,
    scoreHandle: Long?,
    fontProvider: FontProvider,
    audioVm: ReaderAudioViewModel,
    readerVm: ReaderViewModel,
    pageTapHintDismissed: Boolean,
    onDismissPageTapHint: () -> Unit,
    /** User opt-out for continuous-playback auto-page-turn (SettingsPrefs `autoFollow` / the display
     * inspector row). See [shouldAutoFollow]. Off ⇒ the page never turns itself during playback and never
     * recenters on pause — full manual page control (parity with vertical/horizontal + iOS). */
    autoFollowEnabled: Boolean = true,
    /** User opt-out for the page-mode tap-zone overlay (SettingsPrefs `pageTurnButtonsVisible` / the
     * display inspector row). When false, [PageTapOverlay] does not render at all — swipe-to-turn still
     * works via the pager itself. Independent of [pageTapHintDismissed], which only gates the one-time
     * onboarding hint drawn on top of the zones (iOS `readerPageTurnButtonsVisible` parity). */
    pageTurnButtonsVisible: Boolean = true,
    /** Annotation layers + capture pipeline, owned by ReaderScreen. Null ⇒ no annotation here. */
    annotation: AnnotationSurfaceState? = null,
    /**
     * Editing seam — the same set the other two surfaces take; see [ReadyScore]'s parameter docs.
     *
     * Page mode edits the same way they do, with two differences this surface has to carry itself. Its document is
     * PAGINATED (`pagedProgramAndBreaks` lays out at the viewport's height, not A4), so every guarded read has to
     * address that document rather than the recompute loop's — which is what
     * [ReaderViewModel.readerLayoutKeyLocked] now does in page mode. And it does not read `_state`, so the
     * selection tint comes back through [ReaderViewModel.pagedTintedProgram] instead of being published for it.
     *
     * [selectionTintArgb] is the reader's accent, resolved once by [ReaderScreen] so every surface tints alike.
     */
    editing: EditUiState = EditUiState(),
    onSelectItem: (ByteArray?) -> Unit = {},
    onTapSeekItem: (ByteArray) -> Unit = {},
    onSetSelectionDuration: (Int) -> Unit = {},
    onSetSelectionDots: (Int) -> Unit = {},
    onToggleSelectionDot: () -> Unit = {},
    onShiftPitch: (Int) -> Unit = {},
    onShiftOctave: (Int) -> Unit = {},
    layoutGeneration: Int = 0,
    isPlaybackActive: Boolean = false,
    selectionTintArgb: UInt = 0u,
) {
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val annotationMode = annotation?.annotationMode == true

    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    // Program pages + their matching document-Y boundaries, published TOGETHER as one state so the
    // pager never renders a page before its boundary exists (two separate states updated by two
    // sequential native calls is what crashed the page-mode switch).
    var pagedData by remember { mutableStateOf<PagedData?>(null) }
    // Suppresses the "clear the tint" re-encode until there is something to clear, so a score that is only read
    // pays no JNI round trip at all — the same guard the vertical surface's tint uses one level up.
    var hasTintedPagedSelection by remember { mutableStateOf(false) }

    // See [ReadyScore]'s identical pair: the tap callbacks are read at call time so a fresh lambda per
    // recomposition does not restart the gesture detector mid-tap.
    val currentOnSelectItem by rememberUpdatedState(onSelectItem)
    val currentOnTapSeekItem by rememberUpdatedState(onTapSeekItem)

    // `deferRaster = false`: a page is about a screenful, so re-recording it per pinch frame is fine —
    // which is what this surface already did. Underfill is START on both axes: a page is viewport-sized
    // at fit, so the underfill case only arises transiently and the top-left is where it belongs.
    val viewport = rememberReaderViewportState(
        deferRaster = false,
        underfillX = ViewportUnderfill.START,
        underfillY = ViewportUnderfill.START,
    )
    val scale = viewport.scale
    // Content translation, derived from the viewport's scroll-space offset. Every consumer below — the
    // cursor, loop, and A–B overlays, the annotation layers, the nav overlay — takes a translation, so
    // convert once here rather than negating at each site.
    val panOffset = Offset(-viewport.offsetX, -viewport.offsetY)

    // Fixed-density rendering: staff is the same physical size on phone and tablet, and the engine
    // reflows more music into wider viewports (iOS parity). The old fit-to-A4 approach forced a
    // fixed 210 mm wrap width regardless of device width, so staff appeared smaller on phone.
    val fitPxPerMM = if (viewportSize.width > 0) fixedPxPerMm(density.density) else 0f
    // Fallbacks apply only before the viewport is measured; the LaunchedEffect's `viewportHeightMm > 0`
    // guard below suppresses any layout call until both dims are real, so these seeds never reach the engine.
    val viewportWidthMm: Double =
        if (fitPxPerMM > 0f) (viewportSize.width / fitPxPerMM).toDouble() else PAGE_WIDTH_MM
    val viewportHeightMm: Double =
        if (fitPxPerMM > 0f) (viewportSize.height / fitPxPerMM).toDouble() else 0.0

    // A page is laid out to the viewport, so the content at scale 1 IS the viewport. No fixed padding,
    // and no per-page variation — this belongs above the pager, not inside a page.
    SideEffect {
        viewport.geometry = ViewportGeometry(
            viewportWidthPx = viewportSize.width.toFloat(),
            viewportHeightPx = viewportSize.height.toFloat(),
            unitContentWidthPx = viewportSize.width.toFloat(),
            unitContentHeightPx = viewportSize.height.toFloat(),
        )
    }

    // Observe layout options so a display-setting change also triggers a re-fetch.
    val layoutOptions by readerVm.layoutOptions.collectAsStateWithLifecycle()

    // Build the per-page program + page breaks whenever the viewport dimensions OR display options
    // change (incl. device rotation and any inspector edit that affects pagination). Width is now
    // included in the key so a wider viewport (e.g. landscape or tablet) triggers a reflow.
    // `layoutGeneration` joins the keys because an EDIT re-lays-out the score: the recompute loop bumps it and
    // republishes its own program, but this surface draws pages it paginated itself, so without this the note you
    // just wrote would not appear until something else moved.
    LaunchedEffect(scoreHandle, viewportWidthMm, viewportHeightMm, layoutOptions, layoutGeneration) {
        if (scoreHandle != null && viewportHeightMm > 0.0) {
            // One atomic native pass: the program + its matching page breaks are computed under a single
            // lock so the recompute loop can't clobber the shared layout cache between them (that mismatch
            // is what blanked the page view when staves were hidden in quick succession).
            val result = readerVm.pagedProgramAndBreaks(viewportWidthMm, viewportHeightMm)
            val pages = result?.first?.pages ?: emptyList()
            val breaks = result?.second ?: DoubleArray(0)
            val consistent = pages.isNotEmpty() && breaks.size == pages.size + 1
            // Publish only when consistent (one boundary per page edge); on a transient inconsistency keep
            // the prior good data rather than blanking the view.
            if (consistent) pagedData = PagedData(pages, breaks)
        }
    }

    // The selection tint, kept OUT of the effect above on purpose: that one re-paginates, and re-engraving the
    // score on every tap is exactly the cost `setEditSelection` exists to avoid. This is the same single cheap
    // re-encode of the already-cached paged document, and it swaps only the pages — the breaks it was paginated
    // with are unchanged, because nothing about the layout moved.
    //
    // It follows `layoutGeneration` too: the effect above republishes UNTINTED pages after every relayout, so the
    // tint has to be re-applied on top, which is the same order the vertical surface's tint runs in.
    val selectedItemBytes = if (editing.isEditing) editing.selectedItem else null
    LaunchedEffect(scoreHandle, selectedItemBytes, layoutGeneration, selectionTintArgb, pagedData?.breaks) {
        if (scoreHandle == null || pagedData == null) return@LaunchedEffect
        val ids = if (editing.isEditing) decodeSelectedItems(selectedItemBytes) else emptyList()
        if (ids.isEmpty() && !hasTintedPagedSelection) return@LaunchedEffect
        hasTintedPagedSelection = ids.isNotEmpty()
        val tinted = readerVm.pagedTintedProgram(ids, selectionTintArgb) ?: return@LaunchedEffect
        val current = pagedData ?: return@LaunchedEffect
        // Only swap when the re-encode produced the same page count the breaks describe — the same consistency
        // rule the fetch above applies, for the same reason.
        if (tinted.pages.size == current.pages.size) {
            pagedData = PagedData(tinted.pages, current.breaks)
        }
    }

    val pagedPages = pagedData?.pages ?: emptyList()
    val breaksMm = pagedData?.breaks ?: DoubleArray(0)
    val pageCount = pagedPages.size
    val pagerState = rememberPagerState(pageCount = { pageCount })

    // Reset zoom + pan on page turn (iOS parity: each page enters at fit-width). Also stops a fling that
    // was still coasting when the page changed under it.
    LaunchedEffect(pagerState.currentPage) { viewport.reset() }

    // A user-initiated page swipe DURING playback suspends auto-page-turn: the reader took
    // manual control of the page, so the playhead's page must not yank them back until they play again or
    // seek. `interactionSource` only emits DragInteraction for real finger drags — the auto-turn's own
    // programmatic `animateScrollToPage` does NOT, so this never self-suspends. No-op when not playing.
    LaunchedEffect(pagerState, audioVm) {
        pagerState.interactionSource.interactions.collect { interaction ->
            if (interaction is DragInteraction.Start) {
                audioVm.suspendPlaybackFollowForManualViewportChange()
            }
        }
    }

    // Auto page-turn: cursor's document-Y (mm) → its page band → animate there.
    //
    // The target page is derived from the cursor and de-duplicated BEFORE it drives the animation.
    // `currentCursor` emits many times per second during playback (and in a burst right after a seek),
    // so collecting it directly with `collectLatest` cancelled the in-flight `animateScrollToPage` on
    // every emission. A cancellation that landed after the pager crossed the snap midpoint left
    // `currentPage` already equal to the target, so the `target != currentPage` guard then suppressed
    // any restart — stranding the pager at a fractional offset between two pages (the "page turn stops
    // half-way" bug, most visible after a seek). Mapping to the target page index and applying
    // `distinctUntilChanged` drops same-page emissions, so a page-turn animation runs to completion and
    // always settles on an integer page. A genuine page change still cancels-and-restarts via
    // `collectLatest`, which is correct: the new target's animation settles cleanly on its own page.
    //
    // The auto-follow gate is applied in `collectLatest` (NOT `mapNotNull`) so `distinctUntilChanged`
    // still tracks the real target page while suspended; otherwise a suspend-then-resume to the same
    // page the playhead already occupies would be deduped away and never snap back.
    LaunchedEffect(scoreHandle, breaksMm.size, breaksMm.firstOrNull(), breaksMm.lastOrNull(), autoFollowEnabled) {
        val h = scoreHandle ?: return@LaunchedEffect
        if (breaksMm.size < 2) return@LaunchedEffect
        combine(audioVm.currentCursor, audioVm.pageAnchorCursor) { real, anchor -> real to anchor }
            .mapNotNull { (real, anchor) ->
                val cursor = anchor ?: real ?: return@mapNotNull null
                val bytes = SheetMusicJNI.nativeCursorFrame(h, ScoreCursorCodec.encode(cursor))
                if (bytes.isEmpty()) return@mapNotNull null
                val yMm = DecodedFrameCodec.decode(bytes).y.toDouble()
                var target = 0
                for (i in 0 until breaksMm.size - 1) {
                    if (yMm >= breaksMm[i] && yMm < breaksMm[i + 1]) { target = i; break }
                    if (i == breaksMm.size - 2) target = i
                }
                // Carry whether this is a playing lookahead (anchor set) so the gate below suspends only
                // the PLAYING auto-turn, mirroring ReadyScore/HorizontalScore.
                PageTurnTarget(target, isPlaying = anchor != null)
            }
            .distinctUntilChanged { a, b -> a.target == b.target }
            .collectLatest { turn ->
                // Auto-follow opt-out (parity: iOS readerAutoFollowEnabled): off ⇒ no auto-page-turn at
                // all (playing or paused) — full manual page control.
                if (!autoFollowEnabled) return@collectLatest
                // While auto-follow is suspended (the reader took manual control of the page during
                // playback — swipe / nav / pinch), skip the playing auto-turn until playback restarts or
                // the cursor is set manually. Mirrors the vertical/horizontal gate + iOS
                // `isPlaybackFollowSuspended`.
                if (turn.isPlaying &&
                    !shouldAutoFollow(autoFollowEnabled, turn.isPlaying, audioVm.isPlaybackFollowSuspended.value)
                ) {
                    return@collectLatest
                }
                if (turn.target != pagerState.currentPage) pagerState.animateScrollToPage(turn.target)
            }
    }

    Box(
        Modifier.fillMaxSize().onSizeChanged { viewportSize = it },
        contentAlignment = Alignment.TopStart,
    ) {
        if (pageCount == 0) return@Box

        HorizontalPager(
            state = pagerState,
            // Only swipe at unit zoom; while zoomed the gesture pans. Annotating freezes the pager too —
            // a horizontal stroke must not turn the page out from under the finger.
            userScrollEnabled = scale == 1f && !annotationMode,
            modifier = Modifier.fillMaxSize(),
        ) { pageIndex ->
            val pg = pagedPages[pageIndex]
            val contentWidthPx = pg.widthMM.toFloat() * fitPxPerMM * scale
            val contentHeightPx = pg.heightMM.toFloat() * fitPxPerMM * scale
            // Page top in absolute document px — used to shift the (absolute) cursor into page-local space.
            val pageTopPx = breaksMm[pageIndex].toFloat() * fitPxPerMM * scale

            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.White)
                    .clipToBounds()
                    // Tap-to-seek + audition, CENTER region only: the left/right edges are the
                    // PageTapOverlay nav zones (page navigation), so a center tap seeks while edge taps
                    // still turn pages — the split is [PAGE_NAV_ZONE_WIDTH_FRACTION], shared with the
                    // overlay that lays those zones out. The page content is drawn page-local (from y=0) and translated
                    // by panOffset; the hit-test wants ABSOLUTE document mm, so fold this page's band
                    // top (pageTopPx) into the content offset — identical to the overlay's panOffset.
                    .pointerInput(
                        scoreHandle,
                        fitPxPerMM,
                        layoutOptions,
                        pageIndex,
                        scale,
                        annotationMode,
                        editing.isEditing,
                        editing.activeVoice,
                    ) {
                        // While annotating, a tap is the start of a stroke — never a seek.
                        if (annotationMode) return@pointerInput
                        val handle = scoreHandle ?: return@pointerInput
                        if (fitPxPerMM <= 0f) return@pointerInput
                        val optionsBytes = layoutOptions.encode()
                        val navZoneWidthPx = size.width * PAGE_NAV_ZONE_WIDTH_FRACTION
                        detectTapGestures { offset ->
                            // Ignore taps inside either edge nav zone — those belong to PageTapOverlay. This
                            // holds while editing too: turning the page has to stay reachable, and iOS likewise
                            // never lets an edit tap take the page-turn region.
                            if (offset.x < navZoneWidthPx || offset.x > size.width - navZoneWidthPx) {
                                return@detectTapGestures
                            }
                            // Read through `viewport`, NOT the `panOffset` local: this lambda is captured by
                            // `pointerInput`, which only restarts its handler when a KEY changes, and a pan
                            // changes none of them. A captured `Offset` would go stale the moment the reader
                            // pans, and the tap would seek to the wrong note with nothing to show for it.
                            //
                            // `pageTopPx` is what turns a page-local tap into ABSOLUTE document mm — the same
                            // conversion the cursor and annotation overlays make, and the only thing page mode
                            // needs that the other two surfaces do not.
                            val contentOffsetPx =
                                Offset(-viewport.offsetX, -viewport.offsetY - pageTopPx)
                            if (editing.isEditing) {
                                // Editing replaces tap-to-seek here as it does on the other surfaces — see
                                // [ReadyScore]'s tap branch for why the read is guarded and has a fast path.
                                val hitTest: (Long) -> ByteArray? = { h ->
                                    editingHitTestForTap(
                                        tap = offset,
                                        contentOffsetPx = contentOffsetPx,
                                        pxPerMM = fitPxPerMM,
                                        scale = viewport.scale,
                                        scoreHandle = h,
                                        activeVoice = editing.activeVoice,
                                        layoutOptionsBytes = optionsBytes,
                                    )
                                }
                                val immediate = readerVm.tryWithReaderLayout(hitTest)
                                if (immediate != null) {
                                    currentOnSelectItem(immediate.value)
                                } else {
                                    scope.launch {
                                        readerVm.withReaderLayout(hitTest)?.let {
                                            currentOnSelectItem(it.value)
                                        }
                                    }
                                }
                                return@detectTapGestures
                            }
                            val cursor = nearestCursorForTap(
                                tap = offset,
                                contentOffsetPx = contentOffsetPx,
                                pxPerMM = fitPxPerMM,
                                scale = viewport.scale,
                                scoreHandle = handle,
                                layoutOptionsBytes = optionsBytes,
                            ) ?: return@detectTapGestures
                            audioVm.handleTap(cursor)
                            // Remember what the playhead landed on, so a later edit session opens there — see
                            // [ReadyScore]'s note, incl. why a bare `.Beat` cursor leaves the last one standing.
                            (cursor as? ScoreCursor.Item)?.let {
                                currentOnTapSeekItem(ScoreItemIDCodec.encode(it.arg0))
                            }
                        }
                    }
                    // Pan, pinch, and fling live INSIDE the pager page (not as a sibling overlay), so
                    // `HorizontalPager` still receives single-finger horizontal swipes at fit:
                    // `allowSingleFingerPan` is false there, so nothing is consumed and the swipe reaches
                    // the pager. Zoomed, the drag pans the page instead and does not turn it.
                    .readerViewportGestures(
                        state = viewport,
                        scope = scope,
                        key = fitPxPerMM,
                        enabled = fitPxPerMM > 0f,
                        // A lambda, not a value: this answer flips the instant a pinch crosses fit, and a
                        // value in the `pointerInput` key list would restart the handler mid-gesture.
                        allowSingleFingerPan = { viewport.scale > 1f && !annotationMode },
                        allowFling = !annotationMode,
                        onManualViewportChange = audioVm::suspendPlaybackFollowForManualViewportChange,
                    ),
                contentAlignment = Alignment.TopStart,
            ) {
                // Page content is already page-local (drawn from y=0); only user pan translates it.
                Box(
                    Modifier
                        .size(
                            width = with(density) { contentWidthPx.toDp() },
                            height = with(density) { contentHeightPx.toDp() },
                        )
                        .graphicsLayer { translationX = panOffset.x; translationY = panOffset.y },
                ) {
                    ScorePage(
                        page = pg,
                        fontProvider = fontProvider,
                        pxPerMM = fitPxPerMM * scale,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                // Cursor overlay works in ABSOLUTE document coords; shift up by this page's top so it
                // lands in page-local space. Off-page cursors fall outside the band and are clipped.
                val abAccent = MaterialTheme.colorScheme.primary
                val aPending by audioVm.repeatPendingA.collectAsStateWithLifecycle()
                val bPending by audioVm.repeatPendingB.collectAsStateWithLifecycle()
                val repeatMode by audioVm.repeatMode.collectAsStateWithLifecycle()
                scoreHandle?.let { h ->
                    // The editing caret and callout, with this page's band shift folded into `panOffset` exactly
                    // as the cursor and annotation overlays fold it. A caret belonging to another page lands
                    // outside the band and is cut by the page Box's `clipToBounds`, which is what iOS's paged
                    // surface does with its own `.clipped()`.
                    val caretItem = if (editing.isEditing) editing.caretItem else null
                    var caretRect by remember { mutableStateOf<EditCaretFrame?>(null) }
                    LaunchedEffect(h, caretItem, layoutGeneration) {
                        caretRect = caretItem?.let { item ->
                            readerVm.withReaderLayout { handle ->
                                caretRectMm(handle, item, EDIT_CARET_MINIMUM_WIDTH_MM)
                            }?.value
                        }
                    }
                    EditingCaretOverlay(
                        rectMm = caretRect,
                        pxPerMM = fitPxPerMM,
                        scale = scale,
                        panOffset = Offset(panOffset.x, panOffset.y - pageTopPx),
                        color = abAccent.copy(alpha = ON_SCREEN_CURSOR_ALPHA),
                        modifier = Modifier.fillMaxSize(),
                    )
                    val selectedItem = if (editing.isEditing) editing.selectedItem else null
                    var calloutRect by remember { mutableStateOf<EditCaretFrame?>(null) }
                    LaunchedEffect(h, selectedItem, layoutGeneration) {
                        calloutRect = selectedItem?.let { item ->
                            readerVm.withReaderLayout { handle ->
                                caretRectMm(handle, item, EDIT_CALLOUT_MINIMUM_WIDTH_MM)
                            }?.value
                        }
                    }
                    if (editing.isEditing && editing.hasSelectionCallout) {
                        EditingCallout(
                            rectMm = calloutRect,
                            isNoteSelected = editing.isNoteSelected,
                            durationKind = editing.calloutDurationKind,
                            dots = editing.calloutDots,
                            isPlaybackActive = isPlaybackActive,
                            pxPerMM = fitPxPerMM,
                            scale = scale,
                            // A page has no fixed vertical inset; the band shift rides in the pan offset below,
                            // which is where every other page-mode overlay carries it too.
                            vPadPx = 0f,
                            viewportPanPx = Offset(viewport.offsetX, viewport.offsetY + pageTopPx),
                            viewportSizePx = viewportSize,
                            // Deliberately zero, unlike the scrolling surfaces. Page mode must not reserve room
                            // for the editing chrome: that inset feeds the viewport height this surface
                            // PAGINATES from, so reserving it would re-flow the whole score the moment the pad
                            // moved. iOS draws the same line (`horizontalEditingInsets` is horizontal-only).
                            bottomClearancePx = 0f,
                            onSetDuration = onSetSelectionDuration,
                            onSetDots = onSetSelectionDots,
                            onToggleDot = onToggleSelectionDot,
                            onShiftPitch = onShiftPitch,
                            onShiftOctave = onShiftOctave,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                    PlaybackCursorOverlay(
                        scoreHandle = h,
                        // `displayCursor` while editing, so the drawn playhead steps aside for the caret — see
                        // [ReadyScore]'s note; the two are the same accent column.
                        cursorFlow = if (editing.isEditing) audioVm.displayCursor else audioVm.currentCursor,
                        pxPerMM = fitPxPerMM,
                        scale = scale,
                        panOffset = Offset(panOffset.x, panOffset.y - pageTopPx),
                        color = abAccent.copy(alpha = ON_SCREEN_CURSOR_ALPHA),
                        modifier = Modifier.fillMaxSize(),
                    )
                    // Loop region highlight only in A–B loop mode (whole-piece repeat would tint the
                    // entire page; iOS parity gates this on `mode == .abLoop`).
                    if (repeatMode == RepeatMode.AB_LOOP) {
                        LoopHighlightOverlay(
                            scoreHandle = h,
                            loopRangeFlow = audioVm.loopRange,
                            pxPerMM = fitPxPerMM,
                            scale = scale,
                            panOffset = Offset(panOffset.x, panOffset.y - pageTopPx),
                            color = abAccent.copy(alpha = 0.15f),
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                    AbBoundaryMarkersOverlay(
                        scoreHandle = h,
                        aMeasure = aPending,
                        bMeasure = bPending,
                        pxPerMM = fitPxPerMM,
                        scale = scale,
                        panOffset = Offset(panOffset.x, panOffset.y - pageTopPx),
                        color = abAccent,
                        modifier = Modifier.fillMaxSize(),
                    )
                    annotation?.let { an ->
                        // Both layers use the same page-local shift as the cursor / loop overlays above:
                        // placements arrive in ABSOLUTE document coordinates, and this page shows the band
                        // starting at `pageTopPx`. Strokes belonging to other pages fall outside the band
                        // and are cut by the page Box's `clipToBounds`.
                        //
                        // No wet-window clamping is needed here (unlike the scrolling surfaces): a page IS
                        // viewport-sized, so even at the 8x zoom ceiling the front buffer stays far inside
                        // the 65536 px limit.
                        val pageOffset = Offset(panOffset.x, panOffset.y - pageTopPx)
                        AnnotationLayers(
                            resolveDisplayTransforms = remember(h) { musicalDisplayTransformsResolver(h) },
                            annotation = an,
                            pxPerMM = fitPxPerMM,
                            scale = scale,
                            isDrawing = false,
                            dryPanOffset = pageOffset,
                            dryModifier = Modifier.fillMaxSize(),
                            wetWorldToScreen = remember(fitPxPerMM, scale, pageOffset) {
                                android.graphics.Matrix().apply {
                                    setScale(fitPxPerMM * scale, fitPxPerMM * scale)
                                    postTranslate(pageOffset.x, pageOffset.y)
                                }
                            },
                            wetModifier = Modifier.fillMaxSize(),
                        )
                    }
                }
            }
        }

        // The nav overlay scales + pans in lockstep with the page content so the buttons zoom with
        // the score (iOS parity). Transform origin is the top-left to match the content box. Gated on
        // the opt-out toggle: swipe-to-turn (the pager itself, above) keeps working even when the tap
        // zones are hidden — only this overlay (and its onboarding hint) disappears.
        if (pageTurnButtonsVisible) {
            PageTapOverlay(
                viewportSize = viewportSize,
                currentPage = pagerState.currentPage,
                pageCount = pageCount,
                showsHint = !pageTapHintDismissed,
                onAnyZoneTouchDown = onDismissPageTapHint,
                // An explicit edge-tap page navigation is a manual page turn → suspend auto-page-turn during
                // playback so the playhead's page doesn't yank the reader back (iOS `jumpToPage`).
                onFirst = {
                    audioVm.suspendPlaybackFollowForManualViewportChange()
                    scope.launch { pagerState.animateScrollToPage(0) }
                },
                onPrev = {
                    audioVm.suspendPlaybackFollowForManualViewportChange()
                    scope.launch { pagerState.animateScrollToPage((pagerState.currentPage - 1).coerceAtLeast(0)) }
                },
                onNext = {
                    audioVm.suspendPlaybackFollowForManualViewportChange()
                    scope.launch {
                        pagerState.animateScrollToPage((pagerState.currentPage + 1).coerceAtMost(pageCount - 1))
                    }
                },
                onLast = {
                    audioVm.suspendPlaybackFollowForManualViewportChange()
                    scope.launch { pagerState.animateScrollToPage(pageCount - 1) }
                },
                modifier = Modifier.graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                    translationX = panOffset.x
                    translationY = panOffset.y
                    transformOrigin = TransformOrigin(0f, 0f)
                },
            )
        }
    }
}

/** Page program + its matching document-Y boundaries, held as one value so they update atomically. */
private class PagedData(val pages: List<EncodablePage>, val breaks: DoubleArray)

/**
 * A resolved auto-page-turn target: the destination page index plus whether it came from a playing
 * lookahead (`pageAnchorCursor` set) vs a paused/manual cursor. `distinctUntilChanged` de-dupes on
 * [target] only, so bursts of the same page don't cancel an in-flight turn animation.
 */
private data class PageTurnTarget(val target: Int, val isPlaying: Boolean)
