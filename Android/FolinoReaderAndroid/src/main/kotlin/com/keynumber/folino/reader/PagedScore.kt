package com.keynumber.folino.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntSize
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.serialization.DecodedFrameCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec
import io.github.jiyimeta.sheetmusic.compose.cursor.LoopHighlightOverlay
import io.github.jiyimeta.sheetmusic.compose.cursor.PlaybackCursorOverlay
import io.github.jiyimeta.sheetmusic.compose.draw.model.EncodablePage
import io.github.jiyimeta.sheetmusic.compose.render.FontProvider
import io.github.jiyimeta.sheetmusic.compose.render.ScorePage
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.launch

/** A4 page width (mm), used only as a pre-measurement fallback seed (page mode now reflows to the viewport). */
private const val PAGE_WIDTH_MM = 210.0

@Composable
fun PagedScore(
    state: ReaderState.Ready,
    scoreHandle: Long?,
    fontProvider: FontProvider,
    audioVm: ReaderAudioViewModel,
    readerVm: ReaderViewModel,
    pageTapHintDismissed: Boolean,
    onDismissPageTapHint: () -> Unit,
) {
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()

    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    // Program pages + their matching document-Y boundaries, published TOGETHER as one state so the
    // pager never renders a page before its boundary exists (two separate states updated by two
    // sequential native calls is what crashed the page-mode switch).
    var pagedData by remember { mutableStateOf<PagedData?>(null) }
    var scale by remember { mutableFloatStateOf(1f) }
    var panOffset by remember { mutableStateOf(Offset.Zero) }

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

    // Observe layout options so a display-setting change also triggers a re-fetch.
    val layoutOptions by readerVm.layoutOptions.collectAsStateWithLifecycle()

    // Build the per-page program + page breaks whenever the viewport dimensions OR display options
    // change (incl. device rotation and any inspector edit that affects pagination). Width is now
    // included in the key so a wider viewport (e.g. landscape or tablet) triggers a reflow.
    LaunchedEffect(scoreHandle, viewportWidthMm, viewportHeightMm, layoutOptions) {
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

    val pagedPages = pagedData?.pages ?: emptyList()
    val breaksMm = pagedData?.breaks ?: DoubleArray(0)
    val pageCount = pagedPages.size
    val pagerState = rememberPagerState(pageCount = { pageCount })

    // Reset zoom + pan on page turn (iOS parity: each page enters at fit-width).
    LaunchedEffect(pagerState.currentPage) { scale = 1f; panOffset = Offset.Zero }

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
    LaunchedEffect(scoreHandle, breaksMm.size, breaksMm.firstOrNull(), breaksMm.lastOrNull()) {
        val h = scoreHandle ?: return@LaunchedEffect
        if (breaksMm.size < 2) return@LaunchedEffect
        audioVm.currentCursor
            .mapNotNull { cursor ->
                if (cursor == null) return@mapNotNull null
                val bytes = SheetMusicJNI.nativeCursorFrame(h, ScoreCursorCodec.encode(cursor))
                if (bytes.isEmpty()) return@mapNotNull null
                val yMm = DecodedFrameCodec.decode(bytes).y.toDouble()
                var target = 0
                for (i in 0 until breaksMm.size - 1) {
                    if (yMm >= breaksMm[i] && yMm < breaksMm[i + 1]) { target = i; break }
                    if (i == breaksMm.size - 2) target = i
                }
                target
            }
            .distinctUntilChanged()
            .collectLatest { target ->
                if (target != pagerState.currentPage) pagerState.animateScrollToPage(target)
            }
    }

    Box(
        Modifier.fillMaxSize().onSizeChanged { viewportSize = it },
        contentAlignment = Alignment.TopStart,
    ) {
        if (pageCount == 0) return@Box

        HorizontalPager(
            state = pagerState,
            userScrollEnabled = scale == 1f, // only swipe at unit zoom; while zoomed the gesture pans
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
                    // Tap-to-seek + audition, CENTER region only: the left/right 12 % edges are the
                    // PageTapOverlay nav zones (page navigation), so a center tap seeks while edge taps
                    // still turn pages. The page content is drawn page-local (from y=0) and translated
                    // by panOffset; the hit-test wants ABSOLUTE document mm, so fold this page's band
                    // top (pageTopPx) into the content offset — identical to the overlay's panOffset.
                    .pointerInput(scoreHandle, fitPxPerMM, layoutOptions, pageIndex, scale) {
                        val handle = scoreHandle ?: return@pointerInput
                        if (fitPxPerMM <= 0f) return@pointerInput
                        val optionsBytes = layoutOptions.encode()
                        val navZoneWidthPx = size.width * 0.12f
                        detectTapGestures { offset ->
                            // Ignore taps inside either edge nav zone — those belong to PageTapOverlay.
                            if (offset.x < navZoneWidthPx || offset.x > size.width - navZoneWidthPx) {
                                return@detectTapGestures
                            }
                            val cursor = nearestCursorForTap(
                                tap = offset,
                                contentOffsetPx = Offset(panOffset.x, panOffset.y - pageTopPx),
                                pxPerMM = fitPxPerMM,
                                scale = scale,
                                scoreHandle = handle,
                                layoutOptionsBytes = optionsBytes,
                            ) ?: return@detectTapGestures
                            audioVm.handleTap(cursor)
                        }
                    }
                    // Pinch-zoom + pan gesture lives INSIDE the pager page (not as a sibling overlay),
                    // so HorizontalPager still receives single-finger horizontal swipes at scale == 1.
                    // At scale == 1 single-finger drags are NOT consumed here → they reach the pager.
                    .pointerInput(fitPxPerMM, pageIndex) {
                        if (fitPxPerMM <= 0f) return@pointerInput
                        awaitEachGesture {
                            awaitFirstDown(requireUnconsumed = false)
                            do {
                                val event = awaitPointerEvent()
                                val activeCount = event.changes.count { it.pressed }
                                if (activeCount >= 2) {
                                    val zoom = event.calculateZoom()
                                    if (zoom != 1f) {
                                        val c = event.calculateCentroid(useCurrent = true)
                                        if (!c.x.isNaN() && !c.y.isNaN()) {
                                            val newScale = (scale * zoom).coerceIn(1f, 8f)
                                            val ratio = newScale / scale
                                            if (ratio != 1f) {
                                                // Anchor the zoom at the gesture centroid (iOS parity).
                                                // The page content scales about its top-left (which sits
                                                // at panOffset), so to keep the content point under the
                                                // centroid `c` fixed across the scale step we move the
                                                // offset to `c - ratio * (c - panOffset)`. Clamp with the
                                                // NEW scale's pan bounds so the focal shift isn't undone.
                                                val nMinPanX = -(size.width * (newScale - 1f)).coerceAtLeast(0f)
                                                val nMinPanY = -(size.height * (newScale - 1f)).coerceAtLeast(0f)
                                                panOffset = Offset(
                                                    (c.x - ratio * (c.x - panOffset.x)).coerceIn(nMinPanX, 0f),
                                                    (c.y - ratio * (c.y - panOffset.y)).coerceIn(nMinPanY, 0f),
                                                )
                                                scale = newScale
                                            }
                                        }
                                    }
                                    val pan = event.calculatePan()
                                    if (pan != Offset.Zero && scale > 1f) {
                                        val minPanX = -(size.width * (scale - 1f)).coerceAtLeast(0f)
                                        val minPanY = -(size.height * (scale - 1f)).coerceAtLeast(0f)
                                        panOffset = Offset(
                                            (panOffset.x + pan.x).coerceIn(minPanX, 0f),
                                            (panOffset.y + pan.y).coerceIn(minPanY, 0f),
                                        )
                                    }
                                    event.changes.forEach { if (it.positionChanged()) it.consume() }
                                } else if (activeCount == 1 && scale > 1f) {
                                    val pan = event.calculatePan()
                                    if (pan != Offset.Zero) {
                                        val minPanX = -(size.width * (scale - 1f)).coerceAtLeast(0f)
                                        val minPanY = -(size.height * (scale - 1f)).coerceAtLeast(0f)
                                        panOffset = Offset(
                                            (panOffset.x + pan.x).coerceIn(minPanX, 0f),
                                            (panOffset.y + pan.y).coerceIn(minPanY, 0f),
                                        )
                                        event.changes.forEach { if (it.positionChanged()) it.consume() }
                                    }
                                }
                            } while (event.changes.any { it.pressed })
                        }
                    },
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
                    PlaybackCursorOverlay(
                        scoreHandle = h,
                        cursorFlow = audioVm.currentCursor,
                        pxPerMM = fitPxPerMM,
                        scale = scale,
                        panOffset = Offset(panOffset.x, panOffset.y - pageTopPx),
                        color = abAccent,
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
                }
            }
        }

        // The nav overlay scales + pans in lockstep with the page content so the buttons zoom with
        // the score (iOS parity). Transform origin is the top-left to match the content box.
        PageTapOverlay(
            viewportSize = viewportSize,
            currentPage = pagerState.currentPage,
            pageCount = pageCount,
            showsHint = !pageTapHintDismissed,
            onAnyZoneTouchDown = onDismissPageTapHint,
            onFirst = { scope.launch { pagerState.animateScrollToPage(0) } },
            onPrev = { scope.launch { pagerState.animateScrollToPage((pagerState.currentPage - 1).coerceAtLeast(0)) } },
            onNext = { scope.launch { pagerState.animateScrollToPage((pagerState.currentPage + 1).coerceAtMost(pageCount - 1)) } },
            onLast = { scope.launch { pagerState.animateScrollToPage(pageCount - 1) } },
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

/** Page program + its matching document-Y boundaries, held as one value so they update atomically. */
private class PagedData(val pages: List<EncodablePage>, val breaks: DoubleArray)
