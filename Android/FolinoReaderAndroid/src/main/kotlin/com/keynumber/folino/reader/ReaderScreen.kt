package com.keynumber.folino.reader

import android.view.WindowManager
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ViewList
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.FabPosition
import androidx.compose.material3.FilledIconToggleButton
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.FloatingActionButtonDefaults
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.contentColorFor
import androidx.compose.material3.SmallFloatingActionButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.ink.strokes.Stroke
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.keynumber.folino.reader.ink.AnnotationCaptureController
import com.keynumber.folino.reader.ink.AnnotationHandoffQueue
import com.keynumber.folino.reader.ink.AnnotationLayers
import com.keynumber.folino.reader.ink.AnnotationSurfaceState
import com.keynumber.folino.reader.ink.AnnotationTool
import com.keynumber.folino.reader.ink.AnnotationToolState
import com.keynumber.folino.reader.ink.AnnotationToolbar
import com.keynumber.folino.reader.ink.AnnotationToolbarDefaults
import com.keynumber.folino.reader.ink.EraseGestureController
import com.keynumber.folino.reader.ink.ErasePhase
import com.keynumber.folino.reader.ink.encodeWireArray
import com.keynumber.folino.reader.pdf.PagedPdfScore
import com.keynumber.folino.reader.pdf.PdfPlaybackNoticeDialog
import com.keynumber.folino.reader.pdf.PdfPlaybackState
import com.keynumber.folino.reader.pdf.PdfVerticalScore
import com.keynumber.folino.reader.swiftjava.FolinoReaderJNI
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import io.github.jiyimeta.sheetmusic.audio.serialization.DecodedFrameCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec
import io.github.jiyimeta.sheetmusic.compose.cursor.LoopHighlightOverlay
import io.github.jiyimeta.sheetmusic.compose.cursor.PlaybackCursorOverlay
import io.github.jiyimeta.sheetmusic.compose.render.BandedScorePage
import io.github.jiyimeta.sheetmusic.compose.render.ScorePage
import io.github.jiyimeta.sheetmusic.compose.render.bundledFontProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.floor
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.shape.GenericShape
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.filled.NavigateBefore
import androidx.compose.material.icons.filled.NavigateNext
import androidx.compose.material3.Surface
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.zIndex
import io.github.jiyimeta.sheetmusic.audio.model.RehearsalMarkEntry
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import org.swift.swiftkit.core.SwiftMemoryManagement

/**
 * The shared Domain decision (`ReaderCapabilities.resolve(format:)`) for this session's format, fetched
 * over JNI — pure delegation, never re-derived here. `isPdf` mirrors what Tasks 1-4 already established
 * via [ReaderState.ReadyPdf]: the reader's own state machine, not a second format check.
 */
private fun fetchReaderCapabilities(isPdf: Boolean): ReaderCapabilitiesWire {
    val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
    val bytes = FolinoReaderJNI.nativeReaderCapabilities(isPdf, arena).toByteArray()
    return ReaderCapabilitiesWireCodec.decode(bytes)
}

/** Bottom inset reserved for the floating playback FAB cluster, so the score content is not hidden
 * under it. Sized to exactly the FAB's occupied height — the FAB (56) plus the Scaffold's default 16
 * edge margin — so the score region's bottom edge just meets the FAB's top with no whitespace gap
 * above it. Horizontal / page modes reserve it as a fixed-content bottom inset; vertical mode adds it
 * as bottom padding *inside* the scroll content, so the last system scrolls clear of the FAB rather
 * than passing under it. Only applied while the seek bar is off (the FAB is shown). */
private val fabClusterReservedHeight = 72.dp

/** Compose [Color] -> 0xRRGGBBAA Long (our neutral annotation color model, matching
 * [InkBrushMapping.colorInt]'s convention) — turns a toolbar palette swatch into the wire color the
 * capture/brush pipeline expects. */
private fun Color.toRgbaLong(): Long {
    val r = (red * 255).toInt().coerceIn(0, 255).toLong()
    val g = (green * 255).toInt().coerceIn(0, 255).toLong()
    val b = (blue * 255).toInt().coerceIn(0, 255).toLong()
    val a = (alpha * 255).toInt().coerceIn(0, 255).toLong()
    return (r shl 24) or (g shl 16) or (b shl 8) or a
}

/**
 * Alpha applied to the on-screen playback cursor fill color (iOS parity: `accent.opacity(0.6)`).
 * The PiP cursor ([ReaderPipContent]) stays fully opaque, so [HorizontalScore] only applies this
 * when it is not rendering into the PiP window (`pipFit == false`).
 */
internal const val ON_SCREEN_CURSOR_ALPHA = 0.6f

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReaderScreen(
    scoreId: String,
    /** The record's real on-disk file name (e.g. a PDF import's `<id>.pdf`), supplied by the App
     * layer rather than looked up here — the Reader module has no dependency on the Library module.
     * A blank value (or a name whose file is missing) fails cleanly via [ReaderViewModel.load]. */
    localFileName: String,
    title: String,
    layoutMode: ReaderLayoutMode = ReaderLayoutMode.VERTICAL,
    displayOptions: LayoutOptions = LayoutOptions.DEFAULT,
    onDisplayOptionsChange: (LayoutOptions) -> Unit = {},
    /** Called once the score's parts load with the staves the file authored as hidden (`<Part><show>0</show>`).
     * The app module seeds these into the per-score hidden set via the ReaderPreferences bridge. */
    onAuthoredHiddenStavesReady: (Set<StaffAddress>) -> Unit = {},
    onBack: () -> Unit,
    onEditInfo: () -> Unit = {},
    /** Opens the share flow for this score (export-format picker → export → system share sheet). The
     * app module owns the export wiring, so the Reader module only triggers it. */
    onShare: () -> Unit = {},
    pageTapHintDismissed: Boolean = false,
    onDismissPageTapHint: () -> Unit = {},
    /** True once the user chose "Don't show again" on the PDF-playback caveat, so it no longer presents itself when
     * a PDF becomes playable. Persisted by the app module under the SAME key iOS uses
     * (`ReaderGlobalSettingsKey.pdfPlaybackNoticeDismissed`). The caveat is still reachable from the reader's PDF
     * label regardless of this flag. */
    pdfPlaybackNoticeDismissed: Boolean = false,
    /** Sets [pdfPlaybackNoticeDismissed] — invoked by the caveat dialog's "Don't show again" action. */
    onDismissPdfPlaybackNotice: () -> Unit = {},
    /** Persisted annotation pen setup (four pen widths, eraser width, selected tool), sourced from the
     * app module's DataStore (Task 9). The VM's live `toolState` is the source of truth for the UI
     * within a session — this value flows INTO the VM via `LaunchedEffect` below, mirroring how
     * `displayOptions` flows into `setLayoutOptions`. Undo/redo history is session-only and never
     * flows through this prop. */
    annotationToolState: AnnotationToolState = AnnotationToolState(),
    /** Persists the annotation pen setup on user change (selecting a tool, changing a width). The app
     * module owns the DataStore write; this screen also updates the VM optimistically so the toolbar's
     * selection ring / width reflect the change instantly rather than waiting on the DataStore
     * round-trip. */
    onAnnotationToolStateChange: (AnnotationToolState) -> Unit = {},
    /** Global A4 reference pitch default (Hz) from SettingsPrefs. Used for the inspector's cents-offset
     * readout (the per-score live value relative to the user's global tuning) and as the inherit value
     * when this score has no per-score A4 override. */
    globalA4ReferenceHz: Double = 440.0,
    /** Per-score master volume (0..1) restored when the score opens. */
    initialMasterVolume: Float = 1.0f,
    /** Per-score tempo multiplier (engine rate) restored when the score opens. */
    initialTempoMultiplier: Float = 1.0f,
    /** Per-score A4 reference pitch (Hz) restored when the score opens (already resolved against the
     * global default when this score had no override). */
    initialA4ReferenceHz: Double = 440.0,
    /** Persists the per-score master volume on user change. */
    persistMasterVolume: (Double) -> Unit = {},
    /** Persists the per-score tempo multiplier on user change. */
    persistTempoMultiplier: (Double) -> Unit = {},
    /** Persists the per-score A4 reference pitch on user change. */
    persistA4ReferenceHz: (Double) -> Unit = {},
    /** Per-score transpose (semitones, −7..7). Drives BOTH halves: the caller folds it into
     * `displayOptions` for the re-spelled layout, and the Reader pushes it to the engine for the
     * matching tuning shift. */
    transposeSemitones: Int = 0,
    /** Persists the per-score transpose value (semitones) on user change. */
    persistTranspose: (Int) -> Unit = {},
    /** Wire string for the current continuation mode (e.g. "playThrough", "loopPlaylist"); shown in the
     * playback inspector's continuation row. */
    continuationModeWire: String = "playThrough",
    /** Persists the continuation mode wire string on user change. */
    onContinuationModeChange: (String) -> Unit = {},
    /** Global metronome-enabled flag (SettingsPrefs) — metronome is global on both platforms. */
    metronomeEnabled: Boolean = false,
    /** Writes the global metronome flag on user change. */
    onMetronomeChange: (Boolean) -> Unit = {},
    /** Persisted per-score program overrides to replay on open, keyed by positional staff address. */
    mixerProgramOverrides: () -> List<Pair<StaffAddress, Int>> = { emptyList() },
    /** Persisted per-score volume overrides to replay on open, keyed by positional staff address. */
    mixerVolumeOverrides: () -> List<Pair<StaffAddress, Float>> = { emptyList() },
    /** Persists a per-score program override after the live engine update. */
    persistStaffProgram: (StaffAddress, Int) -> Unit = { _, _ -> },
    /** Bank-128 drum kits for the mixer's percussion picker. Owned by shared Swift and injected by the
     * composition root, which is the only layer that sees both the JNI catalog and this screen. */
    drumKits: List<DrumKitOption> = emptyList(),
    /** Kit family display names, indexed by [DrumKitOption.familyIndex]. */
    drumKitFamilyNames: List<String> = emptyList(),
    /** Persists a per-score volume override after the live engine update. */
    persistStaffVolume: (StaffAddress, Float) -> Unit = { _, _ -> },
    /** When true, PiP is enabled in Settings: show the toolbar PiP button and allow auto-enter. */
    pipEnabled: Boolean = false,
    /** When true (SettingsPrefs default), the screen is kept from dimming/locking while the Reader
     * is on screen — applied via [KeepScreenOn]. */
    keepScreenAwake: Boolean = true,
    /** When true, play() counts a measure of clicks in before the score starts (global SettingsPrefs). */
    countInEnabled: Boolean = false,
    /** Writes the global count-in flag — the playback inspector offers the same toggle Settings does,
     * mirroring iOS, since it is a decision you make right before pressing play. */
    onCountInChange: (Boolean) -> Unit = {},
    /** When true, show the full-width seek bar (bottom bar); when false, the floating play FAB. */
    showSeekBar: Boolean = true,
    onShowSeekBarChange: (Boolean) -> Unit = {},
    /** When true (SettingsPrefs default), continuous playback auto-scrolls / auto-page-turns the score and
     * pausing recenters the viewport on the playhead; when false, the reader keeps full manual control of
     * the viewport during playback. Mirrors iOS `readerAutoFollowEnabled`. */
    autoFollowEnabled: Boolean = true,
    onAutoFollowChange: (Boolean) -> Unit = {},
    /** When true (SettingsPrefs default), the page-mode tap zones (edge buttons that turn the page) render;
     * when false, only swipe-to-turn remains. Has no effect outside page mode. Mirrors iOS
     * `readerPageTurnButtonsVisible`. */
    pageTurnButtonsVisible: Boolean = true,
    onPageTurnButtonsVisibleChange: (Boolean) -> Unit = {},
    /** Loads the persisted global repeat mode (suspending so the DataStore value is resolved before
     * the controller is installed). */
    initialRepeatModeLoader: suspend () -> RepeatMode = { RepeatMode.OFF },
    /** Loads this score's persisted A–B range (per-score Room row), or null. */
    loadAbRange: () -> AbRepeatRange? = { null },
    /** Persists this score's A–B range (null clears it). */
    persistAbRange: (AbRepeatRange?) -> Unit = {},
    /** Persists the global sticky repeat mode. */
    persistRepeatMode: (RepeatMode) -> Unit = {},
    /** Non-null only when the Reader was opened from a playlist; enables the continuation control + auto-advance. */
    playlistId: String? = null,
    /** Live, position-ordered (score id, localFileName) pairs of the current playlist (re-derived
     * each call; never a frozen snapshot). localFileName rides alongside the id the same way it
     * does everywhere else in this screen — the host resolves it, the Reader is only ever told it. */
    playlistQueueProvider: suspend () -> List<Pair<String, String>> = { emptyList() },
    /** The global sticky continuation mode (re-read each end-of-score so a Settings change is picked up). */
    continuationModeProvider: suspend () -> PlaylistContinuationMode = { PlaylistContinuationMode.PLAY_THROUGH },
    /** Asks the host to retarget the Reader to (scoreId, localFileName) in place (host sets its
     * currentScoreId / currentLocalFileName). */
    onRetargetScore: (String, String) -> Unit = { _, _ -> },
    readerVm: ReaderViewModel = viewModel(),
    audioVm: ReaderAudioViewModel = viewModel(),
    // Analytics seams. The Reader module cannot import the analytics library, so the app layer passes
    // these callbacks and ReaderScreen only decides WHEN each fires (parity with iOS playback events).
    // All default to no-ops so existing callers / tests compile unchanged.
    onAnalyticsPlaybackStarted: () -> Unit = {},
    onAnalyticsPlaybackPaused: () -> Unit = {},
    onAnalyticsPlaybackCompleted: () -> Unit = {},
    onAnalyticsTransportPrevious: () -> Unit = {},
    onAnalyticsTransportNext: () -> Unit = {},
    onAnalyticsSeek: () -> Unit = {},
) {
    val context = LocalContext.current
    val fontProvider = remember(context) { bundledFontProvider(context) }

    // Applies for as long as ReaderScreen is composed (including while shown in PiP), and clears the
    // instant it isn't — either the pref flips off or the Reader is navigated away from.
    KeepScreenOn(keepScreenAwake)

    val state by readerVm.state.collectAsStateWithLifecycle()
    // What this session's format allows — the shared Domain decision, read over JNI and never
    // re-derived here. `isPdf` is the reader's own state-machine signal (Tasks 1-4), not a second format
    // check. Gates the layout-mode picker + transpose/staff/clef controls (DisplayInspectorSheet) and
    // whether the transport is enabled at all (below).
    val isPdf = state is ReaderState.ReadyPdf
    val capabilities = remember(isPdf) { fetchReaderCapabilities(isPdf) }
    // Whether transport should be enabled right now: scores always, PDFs only once their background OMR
    // parse (Task 12) succeeds. Delegated to the shared rule rather than inlining
    // `canPlay || isPdfPlaybackReady` — Android must not re-derive that policy in Kotlin.
    val pdfPlayback by readerVm.pdfPlayback.collectAsStateWithLifecycle()
    val canPlayNow = remember(capabilities, pdfPlayback) {
        FolinoReaderJNI.nativeCanPlayNow(capabilities.canPlay, pdfPlayback is PdfPlaybackState.Ready)
    }
    val scoreHandle by readerVm.scoreHandle.collectAsStateWithLifecycle()
    // The live layout-options snapshot the recompute loop feeds nativeComputeLayout; the tap
    // hit-test must reuse this exact blob (its hidden-staff set) so re-addressing stays in lockstep.
    val layoutOptions by readerVm.layoutOptions.collectAsStateWithLifecycle()

    // Annotation (Sub-plan E, VERTICAL mode only for this MVP). `toolState` is the toolbar's live
    // selection (Task 8: held in the VM, mirroring `layoutOptions`/`setLayoutOptions`; Task 9: the
    // `annotationToolState` prop above seeds it from DataStore on (re)compose, and the toolbar's
    // onSelect/onWidthChange persist back through `onAnnotationToolStateChange` — see the two call
    // sites below for the exact wiring); `drawings` is the committed layer rendered by the dry overlay
    // and persisted by the VM's debounced save; `canUndo`/`canRedo` gate the toolbar's undo/redo
    // buttons (undo/redo history is session-only, never persisted).
    val annotationMode by readerVm.annotationMode.collectAsStateWithLifecycle()
    val drawings by readerVm.drawings.collectAsStateWithLifecycle()
    val toolState by readerVm.toolState.collectAsStateWithLifecycle()
    val canUndo by readerVm.canUndo.collectAsStateWithLifecycle()
    val canRedo by readerVm.canRedo.collectAsStateWithLifecycle()
    // The active pen's wire color (0xRRGGBBAA), derived from the toolbar palette index — used for both
    // the wet-stroke brush (ReadyScore) and the committed capture below. Falls back to swatch 0 if the
    // selected tool is the eraser (the brush is unused then; see ReadyScore's `annotationWidthMm` doc)
    // OR if the pen's colorIndex is out of range for the current palette — `getOrElse` rather than a
    // plain index so a future persisted index (Task 9) that no longer fits `DEFAULT_COLORS` degrades to
    // swatch 0 instead of throwing out of composition.
    val penColorRGBA = AnnotationToolbarDefaults.DEFAULT_COLORS.getOrElse(
        (toolState.selected as? AnnotationTool.Pen)?.colorIndex ?: 0,
    ) { AnnotationToolbarDefaults.DEFAULT_COLORS[0] }.toRgbaLong()
    // Off-main scope for AnnotationCaptureController.capture (chains 5 sync native JNI calls) and for
    // EraseGestureController's calls (via annotationScope.launch inside its own handle()).
    val annotationScope = rememberCoroutineScope()

    // Wet→dry ink handoff (see AnnotationHandoffQueue's own doc for why retention exists at all).
    // Hoisted here rather than local to ReadyScore: the toolbar's undo/redo buttons live in this
    // Scaffold's bottomBar — a sibling of ReadyScore, not a descendant — and the eraser gesture handler
    // built below needs it too. Both must release every retained wet copy before they swap the
    // annotation layer out from under it, or a not-yet-painted wet stroke could keep rendering for up
    // to MAX_WET_RETENTION_MS after the drawing it belongs to was undone/erased. Passed down into
    // ReadyScore as a parameter so the whole screen shares exactly one instance.
    val inkHandoff = remember { AnnotationHandoffQueue<DrawingAnchorWire>() }

    // Owns the BEGIN/MOVE/END erase-drag state machine (Task 8; extracted to `EraseGestureController` in
    // Task 11 so a PDF surface's own page-anchored eraser drives the identical generation/history-push
    // bookkeeping instead of re-deriving it — see that class's own field docs for the hazards it guards
    // against). `remember`ed (not rebuilt every recomposition) so an in-flight drag survives a
    // recomposition mid-gesture; not shared across a layout-mode switch on purpose (see its class doc).
    val eraseController = remember { EraseGestureController() }

    // For the content Box's width report below (its `onSizeChanged` is not a composable scope).
    val readerDensity = LocalDensity.current
    // Bumped on every layout recompute; re-anchors the annotation overlay so committed ink follows a reflow.
    val layoutGeneration by readerVm.layoutGeneration.collectAsStateWithLifecycle()

    // One bundle for all three score surfaces (vertical / horizontal / page), so each takes a single
    // parameter instead of repeating the same ten. The erase state machine and the capture pipeline are
    // built HERE, not inside a surface, because they have to survive a layout-mode switch: recomposing
    // into a different surface mid-commit would otherwise strand an in-flight stroke with no one left to
    // deliver its `onCommitted`.
    val annotationSurface = AnnotationSurfaceState(
        annotationMode = annotationMode,
        drawings = drawings,
        layoutGeneration = layoutGeneration,
        colorRGBA = penColorRGBA,
        brushWidthWorld = toolState.activeWidth,
        eraserMode = toolState.selected is AnnotationTool.Eraser,
        eraserWidthWorld = toolState.eraserWidth,
        onEraseGesture = { phase, pathWorld ->
            // Presets are DIAMETERS; applyErase wants a geometric radius.
            val radiusWorld = toolState.eraserWidth / 2f
            eraseController.handle(
                scope = annotationScope,
                phase = phase,
                pathWorld = pathWorld,
                radiusWorld = radiusWorld,
                // An unloaded score has nothing to erase against — mirrors the original per-phase
                // `scoreHandle != null` gate this class used to inline before it became shared with the
                // PDF surfaces (which always pass `ready = true`, having no scoreHandle concept at all).
                ready = scoreHandle != null,
                scoreHandle = scoreHandle,
                currentDrawings = readerVm::currentDrawings,
                resolveDisplayTransforms = { pending ->
                    // Rebuilt every call rather than `remember`ed: `scoreHandle` is a plain composed
                    // value (not a stable holder), so a fresh closure each time is the only way to
                    // guarantee this always resolves against the CURRENT handle — matching every other
                    // call site's own null re-check. `EraseGestureController.handle` never uses this
                    // as a `LaunchedEffect` key (unlike `AnnotationDryOverlay`'s own resolver), so the
                    // fresh-instance cost here is a non-issue.
                    val handle = scoreHandle
                    if (handle == null) ByteArray(0) else musicalDisplayTransformsResolver(handle)(pending)
                },
                releaseWetRetention = inkHandoff::releaseAll,
                onInProgress = readerVm::eraseInProgress,
                onCommitted = readerVm::eraseCommitted,
            )
        },
        inkHandoff = inkHandoff,
        onStrokeCaptured = { stroke, onCommitted ->
            // Capture chains 5 sync native JNI calls (E5-M3) — off the main thread, then
            // hand the result back to the VM (StateFlow.value assignment is thread-safe).
            // `onCommitted` closes the wet→dry handoff and must run on the main thread; it
            // takes the committed drawing, or null when the stroke never anchored.
            val handle = scoreHandle
            if (handle == null) {
                onCommitted(null)
            } else {
                // Snapshot the pen's color/width into locals HERE, on the main thread, before
                // launching — `penColorRGBA` is already a plain captured value, but
                // `toolState.activeWidth` is a live property re-read: referencing it directly
                // inside the coroutine below would re-evaluate it whenever that line actually
                // runs (after the async JNI capture chain), so a color/width change in the gap
                // between finger-up and the coroutine running would commit the stroke with the
                // NEW value while the wet layer had drawn it with the OLD one — a visible jump
                // at the wet→dry handoff. Locals fix the values to what was active when the
                // stroke actually finished.
                val capturedColorRGBA = penColorRGBA
                val capturedWidthMm = toolState.activeWidth
                annotationScope.launch(Dispatchers.Default) {
                    val drawing = AnnotationCaptureController.capture(
                        stroke = stroke,
                        tool = AnnotationSurfaceState.WET_STROKE_TOOL,
                        colorRGBA = capturedColorRGBA,
                        baseWidthSp = capturedWidthMm,
                        scoreHandle = handle,
                    )
                    drawing?.let { readerVm.addDrawing(it) }
                    withContext(Dispatchers.Main) { onCommitted(drawing) }
                }
            }
        },
    )

    LaunchedEffect(scoreId) {
        readerVm.load(scoreId, localFileName)
        // Re-fires once per scoreId (same effect as `load`), so this primes persistence + rehydrates
        // the dry overlay's drawings exactly once per score open, not on every recomposition.
        readerVm.onAnnotationOpened(scoreId)
    }
    // Install the repeat controller once per score: resolve the persisted global mode (suspending)
    // and wire per-score A–B persistence. The controller loads any saved A–B range here; the active
    // loop is (re)applied after the engine finishes preparing.
    LaunchedEffect(scoreId) {
        audioVm.installRepeatController(
            initialMode = initialRepeatModeLoader(),
            loadRange = loadAbRange,
            persistRange = persistAbRange,
            persistMode = persistRepeatMode,
        )
    }

    // Set when this screen initiates an auto-advance; consumed once the next score reaches PREPARED.
    var pendingAutoplay by remember { mutableStateOf(false) }

    // End-of-score handling: on a real end-of-score, log playback completion (for EVERY score), then —
    // only in a playlist context — ask the shared Domain decision (via JNI) what to do next, re-deriving
    // the live queue + re-reading the global continuation mode each time (parity with iOS).
    LaunchedEffect(playlistId, scoreId) {
        audioVm.onReachedEnd.collect {
            // Genuine end-of-score: the VM clears hasLoadedIntoPlayback before emitting onReachedEnd, so
            // a teardown (onCleared stop) / mid-score re-prepare cursor-nil cannot re-fire this. Log
            // completion for every score — iOS logs completion for standalone scores too, not only the
            // playlist auto-advance case — so fire it before (and independent of) the playlist decision.
            onAnalyticsPlaybackCompleted()

            if (playlistId == null) return@collect
            val queue = playlistQueueProvider()
            val index = queue.indexOfFirst { it.first == scoreId }
            if (index < 0) return@collect
            val next = com.keynumber.folino.reader.swiftjava.FolinoReaderJNI.nativePlaylistNextAction(
                index.toLong(),
                queue.size.toLong(),
                audioVm.repeatMode.value.wire,
                continuationModeProvider().wire,
            ).toInt()
            if (next in queue.indices) {
                pendingAutoplay = true
                onRetargetScore(queue[next].first, queue[next].second)
            }
        }
    }
    LaunchedEffect(scoreHandle) {
        scoreHandle?.let {
            // Seed the per-score playback scalars (master volume / tempo / A4) before prepare, so the
            // engine re-syncs to the user's saved values once the player is prepared. The global A4 is
            // also stored so the inspector can show the per-score value's cents offset.
            audioVm.seedPlaybackScalars(
                masterVolume = initialMasterVolume,
                tempoMultiplier = initialTempoMultiplier,
                a4ReferenceHz = initialA4ReferenceHz,
                globalA4ReferenceHz = globalA4ReferenceHz,
            )
            audioVm.preparePlayback(it)
        }
    }
    // Metronome is global (SettingsPrefs). Push the current global value into the engine + VM so the
    // soundfont-reload re-push keeps it, and re-push whenever the global flag changes.
    LaunchedEffect(metronomeEnabled, scoreHandle) {
        audioVm.setMetronomeEnabled(metronomeEnabled)
    }
    // Audible half of transpose. The notation half rides on `displayOptions` (a re-spelled layout); this
    // retunes the melodic channels. Re-pushed on scoreHandle because a fresh synth starts at concert
    // pitch, so a score opened while transposed would otherwise sound untransposed.
    LaunchedEffect(transposeSemitones, scoreHandle) {
        audioVm.setTranspose(transposeSemitones)
    }
    // Count-in is global (SettingsPrefs), consumed by the engine at the next play().
    LaunchedEffect(countInEnabled, scoreHandle) {
        audioVm.setCountInEnabled(countInEnabled)
    }
    // Parts descriptor → flat staffIndex map: the mixer addresses channels by a flat staffIndex, the
    // ReaderPreferences bridge persists overrides by positional StaffAddress. This map (built from the
    // same parts→staves enumeration the engine uses) bridges the two for both replay and persistence.
    val mixerParts by readerVm.parts.collectAsStateWithLifecycle()
    val staffAddressByIndex = remember(mixerParts) { mixerParts.staffAddressByIndex() }
    val addressToIndex = remember(staffAddressByIndex) {
        staffAddressByIndex.entries.associate { (index, addr) -> addr to index }
    }
    // Once the parts load, hand the file's authored-hidden staves (<Part><show>0</show>) to the app layer to
    // seed into the per-score hidden set. Idempotent on the bridge (reconciles once), so re-firing is safe.
    LaunchedEffect(mixerParts) {
        if (mixerParts.isNotEmpty()) onAuthoredHiddenStavesReady(mixerParts.authoredHiddenStaffAddresses())
    }
    // Replay persisted per-staff mixer overrides after each prepare. Resolve each saved StaffAddress to
    // its current flat staffIndex via the parts map; skip any address that doesn't resolve (guards the
    // channel-order assumption against a score whose part/staff layout changed since the override was
    // saved). Solo / mute are session-only and intentionally not replayed.
    LaunchedEffect(scoreHandle, addressToIndex) {
        audioVm.installOnPrepared {
            val engine = audioVm.engine.value ?: return@installOnPrepared
            mixerProgramOverrides().forEach { (addr, program) ->
                addressToIndex[addr]?.let { engine.setStaffProgram(it, program) }
            }
            mixerVolumeOverrides().forEach { (addr, volume) ->
                addressToIndex[addr]?.let { engine.setStaffVolume(it, volume) }
            }
        }
    }
    // Push display options into the VM; its recompute loop re-runs nativeComputeLayout on change.
    LaunchedEffect(displayOptions) { readerVm.setLayoutOptions(displayOptions) }

    // Push the persisted annotation pen setup into the VM (Task 9). DataStore is the source of truth
    // across restarts; the toolbar's onSelect/onWidthChange below already write the VM optimistically,
    // so when this later re-fires with the same value the setAnnotationToolState is idempotent — no
    // feedback loop, because a StateFlow re-set to an equal value doesn't trigger any further collection.
    LaunchedEffect(annotationToolState) { readerVm.setAnnotationToolState(annotationToolState) }

    val pipActive by ReaderPipController.isInPipMode.collectAsStateWithLifecycle()
    val playbackState by audioVm.state.collectAsStateWithLifecycle()
    // Gates the top-bar annotation toggle: disabled while playing (parity w/ iOS).
    val isPlaying = playbackState == PlaybackState.PLAYING

    // Mutual exclusion: annotation is strictly VERTICAL + not-playing. Auto-exit whenever either
    // condition stops holding (layout mode switches away from VERTICAL, or playback starts) so
    // annotation mode never lingers active behind a layout that has no overlay/gating support for it —
    // without this, playing while annotating would leave the score frozen via the detached ScrollState
    // (scrollModifier stays `Modifier` while `annotationMode` is true, regardless of `isPlaying`).
    LaunchedEffect(layoutMode, isPlaying) {
        if (layoutMode != ReaderLayoutMode.VERTICAL || isPlaying) readerVm.setAnnotationMode(false)
    }

    // Analytics: one central playback-state observer covers every play/pause path exactly once (the
    // TransportBar FAB, the floating FAB, and the PiP transport all funnel through audioVm.state).
    // Fire "started" on every transition INTO PLAYING (tap-play, autoplay, resume-after-pause — iOS
    // fires on every transition to playing) and "paused" only on PLAYING→PAUSED. A transition to
    // STOPPED is end-of-score / close, not a pause, so it is ignored here. Keyed on Unit so it neither
    // re-launches nor double-fires on recomposition / in-place score retargets; the previous-state
    // seed equals the StateFlow's current value so the first (conflated) emission never spuriously fires.
    LaunchedEffect(Unit) {
        var previousPlaybackState = audioVm.state.value
        audioVm.state.collect { current ->
            if (current == PlaybackState.PLAYING && previousPlaybackState != PlaybackState.PLAYING) {
                onAnalyticsPlaybackStarted()
            } else if (current == PlaybackState.PAUSED && previousPlaybackState == PlaybackState.PLAYING) {
                onAnalyticsPlaybackPaused()
            }
            previousPlaybackState = current
        }
    }

    // Continuous playback implies auto-play: once the retargeted score finishes preparing, start it.
    LaunchedEffect(playbackState) {
        if (playbackState == PlaybackState.PREPARED && pendingAutoplay) {
            audioVm.engine.value?.play()
            pendingAutoplay = false
        }
    }

    // Publish PiP eligibility while the Reader is on screen.
    LaunchedEffect(state, pipEnabled, playbackState) {
        ReaderPipController.setPlaying(playbackState == PlaybackState.PLAYING)
        ReaderPipController.setEligible(
            state is ReaderState.Ready && pipEnabled && playbackState == PlaybackState.PLAYING,
        )
    }

    // Publish the PiP window aspect from the visible staff count heuristic, matching the iOS
    // implementation: staves present in the score that are not hidden (at least 1). Uses
    // visiblePipStaffCount to avoid undercounting when hiddenStaves contains stale addresses.
    // Recomputed when PiP is toggled, parts change, or hidden-stave selection changes.
    LaunchedEffect(pipEnabled, mixerParts, layoutOptions.hiddenStaves) {
        if (!pipEnabled) return@LaunchedEffect
        val visibleStaves = visiblePipStaffCount(mixerParts, layoutOptions.hiddenStaves)
        ReaderPipController.setContentAspect(
            com.keynumber.folino.reader.swiftjava.FolinoReaderJNI.nativePipWindowAspect(
                visibleStaves.toLong(), 6.0, 1.0, PIP_MAX_ASPECT,
            ),
        )
    }

    // Register transport hooks the in-window RemoteActions call; clear them on exit. ±10s is
    // implemented via seek (the engine has no verified skip()): clamp to [0, total].
    DisposableEffect(Unit) {
        ReaderPipController.onTogglePlayPause = {
            val e = audioVm.engine.value
            if (audioVm.state.value == PlaybackState.PLAYING) e?.pause() else e?.play()
        }
        ReaderPipController.onSkip = { delta ->
            audioVm.engine.value?.let { e ->
                val target = (audioVm.currentTimeSeconds.value + delta)
                    .coerceIn(0.0, audioVm.totalTimeSeconds.value)
                e.seek(target)
            }
        }
        onDispose { ReaderPipController.reset() }
    }

    // Flush any debounced-but-unsaved annotation edits on teardown (screen close / process-death path).
    DisposableEffect(Unit) { onDispose { readerVm.flushAnnotations() } }

    var showInspector by remember { mutableStateOf(false) }
    var showDisplayInspector by remember { mutableStateOf(false) }

    // The PDF-playback caveat. Presented automatically the first time a PDF becomes playable — unless it was
    // dismissed for good — and on demand from the top bar's PDF label thereafter. Same three-part gate iOS applies in
    // `ReaderRootScreen`: ready, not yet auto-shown, not dismissed.
    //
    // `hasAutoShownPdfNotice` is scoped to the READER OPEN, not to the document: neither the `remember` nor the
    // effect is keyed on `scoreId`, so retargeting the reader in place — which is what a playlist advance does
    // (`onRetargetScore`, no navigation) — does NOT re-arm it. This is iOS's behavior, where the equivalent flag is a
    // plain `@State` on `ReaderRootScreen` and survives the same in-place retarget. Keying on `scoreId` would make a
    // playlist of N PDFs interrupt playback with N modals, one per parse.
    var showPdfNotice by remember { mutableStateOf(false) }
    var hasAutoShownPdfNotice by remember { mutableStateOf(false) }
    // The PRESENTED dialog, unlike the flag above, must not survive a retarget: it explains one specific PDF's
    // playback, and the incoming document is a different one (it would also be re-read as `Parsing`, so an open
    // "couldn't read this PDF" body would silently turn back into the best-effort body under the user). Declared
    // BEFORE the auto-present effect so that if a retarget and a parse ever land in the same composition, the close
    // runs first and cannot swallow a legitimate first presentation.
    LaunchedEffect(scoreId) { showPdfNotice = false }
    LaunchedEffect(pdfPlayback, pdfPlaybackNoticeDismissed) {
        if (pdfPlayback !is PdfPlaybackState.Ready) return@LaunchedEffect
        if (hasAutoShownPdfNotice || pdfPlaybackNoticeDismissed) return@LaunchedEffect
        hasAutoShownPdfNotice = true
        showPdfNotice = true
    }
    // Open at full height so the dense inspector shows as many rows as possible at once.
    val inspectorSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val displaySheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    if (pipActive) {
        ReaderPipContent(readerVm = readerVm, audioVm = audioVm)
        return
    }

    Scaffold(
        topBar = {
            ReaderTopBar(
                title = title,
                onBack = onBack,
                onShare = onShare,
                onEditInfo = onEditInfo,
                onPlaybackControls = { showInspector = true },
                onDisplaySettings = { showDisplayInspector = true },
                annotationMode = annotationMode,
                // Available in every layout mode; only playback locks it out (a moving cursor and a
                // pinned stylus fight over the same surface, and iOS gates it the same way).
                annotationEnabled = !isPlaying,
                onToggleAnnotate = readerVm::toggleAnnotationMode,
                isPdf = isPdf,
                onShowPdfNotice = { showPdfNotice = true },
            )
        },
        bottomBar = {
            if (annotationMode) {
                AnnotationToolbar(
                    state = toolState,
                    presetColors = AnnotationToolbarDefaults.DEFAULT_COLORS,
                    canUndo = canUndo,
                    canRedo = canRedo,
                    // Optimistic VM write + persist callback (Task 9): update the VM immediately so the
                    // toolbar's selection ring / width reflect the change on this frame — the DataStore
                    // round-trip through onAnnotationToolStateChange -> MainActivity -> collectAsState ->
                    // LaunchedEffect(annotationToolState) above would otherwise visibly lag by a frame or
                    // more. That later re-set is idempotent (see the LaunchedEffect's own comment).
                    onSelect = { tool ->
                        val next = toolState.copy(selected = tool)
                        readerVm.setAnnotationToolState(next)
                        onAnnotationToolStateChange(next)
                    },
                    onWidthChange = { width ->
                        val next = toolState.withWidthForSelected(width)
                        readerVm.setAnnotationToolState(next)
                        onAnnotationToolStateChange(next)
                    },
                    onUndo = {
                        // A not-yet-painted wet stroke must not linger on the wet layer for
                        // MAX_WET_RETENTION_MS after undo removes the drawing it belongs to.
                        inkHandoff.releaseAll()
                        readerVm.undoDrawings()
                    },
                    onRedo = {
                        inkHandoff.releaseAll()
                        readerVm.redoDrawings()
                    },
                )
            } else if (showSeekBar) {
                TransportBar(
                    audioVm = audioVm,
                    enabled = canPlayNow,
                    onAnalyticsTransportPrevious = onAnalyticsTransportPrevious,
                    onAnalyticsTransportNext = onAnalyticsTransportNext,
                    onAnalyticsSeek = onAnalyticsSeek,
                )
            }
        },
        floatingActionButton = {
            if (!showSeekBar) PlaybackFab(audioVm, enabled = canPlayNow, onAnalyticsSeek = onAnalyticsSeek)
        },
        floatingActionButtonPosition = FabPosition.End,
    ) { padding ->
        Box(
            Modifier
                .padding(padding)
                .fillMaxSize()
                // Fill the whole content area (incl. the band the floating FAB sits over) with the
                // same white the score page draws on, so the seek-bar-off bottom area reads as one
                // continuous white surface rather than the theme background tint.
                .background(Color.White)
                .padding(
                    bottom = if (!showSeekBar &&
                        (layoutMode == ReaderLayoutMode.HORIZONTAL || layoutMode == ReaderLayoutMode.PAGE)
                    ) {
                        fabClusterReservedHeight
                    } else {
                        0.dp
                    },
                )
                // Report the layout width from HERE, not from the score surface below. This Box is
                // composed for every state (Loading included), so the engine gets the real width before
                // it lays anything out. Measuring it inside the Ready branch instead meant the width was
                // only known after a layout had already been computed and drawn at the seed width — the
                // score then visibly stretched sideways when the second layout landed. The score
                // surfaces are `fillMaxSize` inside this Box, so the width measured here is the one they
                // render into; only the bottom padding above differs.
                .onSizeChanged { size ->
                    if (size.width > 0) readerVm.setLayoutWidthMm(layoutWidthMm(size.width, readerDensity.density))
                },
            contentAlignment = Alignment.Center,
        ) {
            when (val s = state) {
                is ReaderState.Loading -> Text("Loading…")
                is ReaderState.Error -> Text(s.message, style = MaterialTheme.typography.bodyLarge)
                is ReaderState.Ready -> when (layoutMode) {
                    ReaderLayoutMode.VERTICAL -> ReadyScore(
                        state = s,
                        scoreHandle = scoreHandle,
                        fontProvider = fontProvider,
                        audioVm = audioVm,
                        layoutOptions = layoutOptions,
                        // Pad the scroll content's bottom by the FAB cluster height (when the seek bar
                        // is off) so the last system can scroll out from under the floating play FAB.
                        bottomContentPad = if (!showSeekBar) fabClusterReservedHeight else 0.dp,
                        annotation = annotationSurface,
                        autoFollowEnabled = autoFollowEnabled,
                    )
                    ReaderLayoutMode.HORIZONTAL -> HorizontalScore(
                        s, scoreHandle, fontProvider, audioVm, layoutOptions,
                        autoFollowEnabled = autoFollowEnabled,
                        annotation = annotationSurface,
                    )
                    ReaderLayoutMode.PAGE -> PagedScore(
                        state = s,
                        scoreHandle = scoreHandle,
                        fontProvider = fontProvider,
                        audioVm = audioVm,
                        readerVm = readerVm,
                        pageTapHintDismissed = pageTapHintDismissed,
                        onDismissPageTapHint = onDismissPageTapHint,
                        autoFollowEnabled = autoFollowEnabled,
                        pageTurnButtonsVisible = pageTurnButtonsVisible,
                        annotation = annotationSurface,
                    )
                }
                is ReaderState.ReadyPdf -> when (layoutMode) {
                    // Horizontal is not reachable for a PDF (Task 5 removed it from the offered modes for
                    // this state), so it falls to the vertical surface below along with VERTICAL itself —
                    // the same "everything else" fallback the plan calls for.
                    ReaderLayoutMode.PAGE -> readerVm.pdfPageSource?.let { pdfSource ->
                        PagedPdfScore(
                            state = s,
                            source = pdfSource,
                            audioVm = audioVm,
                            readerVm = readerVm,
                            pageTapHintDismissed = pageTapHintDismissed,
                            onDismissPageTapHint = onDismissPageTapHint,
                            autoFollowEnabled = autoFollowEnabled,
                            pageTurnButtonsVisible = pageTurnButtonsVisible,
                            annotation = annotationSurface,
                        )
                    }
                    else -> readerVm.pdfPageSource?.let { pdfSource ->
                        PdfVerticalScore(
                            state = s,
                            source = pdfSource,
                            audioVm = audioVm,
                            readerVm = readerVm,
                            bottomContentPad = if (!showSeekBar) fabClusterReservedHeight else 0.dp,
                            annotation = annotationSurface,
                            autoFollowEnabled = autoFollowEnabled,
                        )
                    }
                }
            }
        }
    }
    if (showPdfNotice) {
        // `Unavailable` is the only state that gets the "couldn't read this PDF" body; `Parsing` still gets the
        // best-effort caveat, matching iOS's own `pdfPlaybackNoticeBodyKey`.
        PdfPlaybackNoticeDialog(
            unavailable = pdfPlayback is PdfPlaybackState.Unavailable,
            onDismiss = { showPdfNotice = false },
            onDontShowAgain = {
                showPdfNotice = false
                onDismissPdfPlaybackNotice()
            },
        )
    }
    if (showInspector) {
        val openingQuarterBpm by readerVm.openingQuarterBpm.collectAsStateWithLifecycle()
        PlaybackInspectorSheet(
            audioVm = audioVm,
            openingQuarterBpm = openingQuarterBpm,
            sheetState = inspectorSheetState,
            onDismiss = { showInspector = false },
            metronomeEnabled = metronomeEnabled,
            onMetronomeChange = onMetronomeChange,
            countInEnabled = countInEnabled,
            onCountInChange = onCountInChange,
            onPersistMasterVolume = persistMasterVolume,
            onPersistTempoMultiplier = persistTempoMultiplier,
            onPersistA4ReferenceHz = persistA4ReferenceHz,
            transposeSemitones = transposeSemitones,
            onTransposeChange = persistTranspose,
            staffAddressByIndex = staffAddressByIndex,
            onPersistStaffProgram = persistStaffProgram,
            drumKits = drumKits,
            drumKitFamilyNames = drumKitFamilyNames,
            onPersistStaffVolume = persistStaffVolume,
            partNames = mixerParts.map { it.name },
            isInPlaylist = playlistId != null,
            continuationModeWire = continuationModeWire,
            onContinuationModeChange = onContinuationModeChange,
        )
    }
    if (showDisplayInspector) {
        val parts by readerVm.parts.collectAsStateWithLifecycle()
        DisplayInspectorSheet(
            options = displayOptions,
            parts = parts,
            sheetState = displaySheetState,
            onDismiss = { showDisplayInspector = false },
            onChange = onDisplayOptionsChange,
            showSeekBar = showSeekBar,
            onShowSeekBarChange = onShowSeekBarChange,
            autoFollowEnabled = autoFollowEnabled,
            onAutoFollowChange = onAutoFollowChange,
            pageTurnButtonsVisible = pageTurnButtonsVisible,
            onPageTurnButtonsVisibleChange = onPageTurnButtonsVisibleChange,
            transposeSemitones = transposeSemitones,
            onTransposeChange = persistTranspose,
            capabilities = capabilities,
        )
    }
}

/**
 * Keeps the device screen from dimming/locking while [enabled] is true, by applying
 * `FLAG_KEEP_SCREEN_ON` to the hosting Activity's window. Re-evaluated whenever [enabled] changes,
 * and cleared on every disposal — a pref flip to false, or this composable leaving the composition
 * (e.g. navigating away from the Reader) — so the flag never outlives the Reader being on screen.
 * `findActivity()` (declared in [ReaderPipController]'s file) walks the `ContextWrapper` chain to the
 * Activity; the flag is a no-op if that lookup ever fails to find one.
 */
@Composable
private fun KeepScreenOn(enabled: Boolean) {
    val context = LocalContext.current
    DisposableEffect(enabled) {
        val window = context.findActivity()?.window
        if (enabled) window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }
}

/**
 * The Reader's top app bar (back arrow + title + the share / edit-info / playback / display action
 * icons). Extracted from [ReaderScreen]'s Scaffold so the screenshot harness can render the REAL bar
 * over its score scenes (mirroring the [DisplayInspectorContent] / [PlaybackInspectorContent] seams).
 * Production behavior is unchanged: [ReaderScreen] delegates its `topBar` here, passing the same
 * callbacks it used inline.
 *
 * PiP is not exposed here — on Android it auto-enters when the user leaves the app during playback;
 * an explicit toolbar button is an iOS idiom we don't mirror.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReaderTopBar(
    title: String,
    onBack: () -> Unit,
    onShare: () -> Unit,
    onEditInfo: () -> Unit,
    onPlaybackControls: () -> Unit,
    onDisplaySettings: () -> Unit,
    modifier: Modifier = Modifier,
    windowInsets: WindowInsets = TopAppBarDefaults.windowInsets,
    /** Whether annotation (pencil) mode is currently active — drives the toggle's checked state. */
    annotationMode: Boolean = false,
    /** Disabled while playback is active (parity w/ iOS: can't annotate while the score is playing). */
    annotationEnabled: Boolean = true,
    onToggleAnnotate: () -> Unit = {},
    /** True while a fixed-layout PDF is open — shows the tappable "PDF" label beside the title. */
    isPdf: Boolean = false,
    /** Re-presents the PDF-playback caveat; invoked by the "PDF" label. */
    onShowPdfNotice: () -> Unit = {},
) {
    TopAppBar(
        modifier = modifier,
        windowInsets = windowInsets,
        // Single-line title that ellipsizes when it doesn't fit, so a long score name never wraps the
        // bar to two rows. A PDF adds the brand label after the title, mirroring iOS's PDF badge: it is
        // what keeps the playback caveat reachable once "Don't show again" has silenced the automatic
        // presentation. Placed here rather than in `actions` so it reads as a property of THIS document
        // rather than as another command, and so it never competes with the action icons for width.
        title = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    title.ifEmpty { "folino" },
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (isPdf) {
                    Spacer(Modifier.width(8.dp))
                    ReaderPdfLabel(onClick = onShowPdfNotice)
                }
            }
        },
        navigationIcon = {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
            }
        },
        actions = {
            IconButton(onClick = onShare) {
                Icon(
                    Icons.Filled.Share,
                    contentDescription = stringResource(R.string.reader_share),
                )
            }
            IconButton(onClick = onEditInfo) {
                Icon(
                    Icons.Outlined.Info,
                    contentDescription = stringResource(R.string.reader_edit_info),
                )
            }
            IconButton(onClick = onPlaybackControls) {
                Icon(Icons.Default.Tune, contentDescription = "Playback controls")
            }
            IconButton(onClick = onDisplaySettings) {
                Icon(
                    Icons.AutoMirrored.Filled.ViewList,
                    contentDescription = stringResource(R.string.reader_display_settings),
                )
            }
            FilledIconToggleButton(
                checked = annotationMode,
                onCheckedChange = { onToggleAnnotate() },
                enabled = annotationEnabled,
            ) {
                Icon(Icons.Filled.Edit, contentDescription = "Annotate")
            }
        },
    )
}

/**
 * The reader's "PDF" marker: the same outlined-chip label the library row uses for a fixed-layout item
 * (`ScoreListScaffold.PdfLabel`), made tappable so it re-presents the PDF-playback caveat — the Android reading of
 * iOS's tappable `PDFBadge`. The text is a brand literal and is intentionally not localized, matching the library's.
 *
 * Being reachable here is what makes the dialog's "Don't show again" safe to offer: the explanation of why playback
 * on a PDF is approximate never becomes unreachable, it just stops interrupting — which is why the touch target
 * matters more than the chip's ~28x16 dp suggests.
 *
 * The target is a real 48 dp box, not a hint: `defaultMinSize` fixes THIS `Box`'s measured size at Material's
 * minimum, and `clickable` is applied inside it, so the clickable node's own hit bounds are the 48 dp box. (An
 * earlier revision put `Modifier.minimumInteractiveComponentSize()` first on the `Text` instead. That is a
 * layout-only modifier — it reports `max(child, 48dp)` and centers the child, leaving the inner `clickable` still
 * bound to the chip. `IconButton` gets a real target from that position only because it pairs it with an explicit
 * `.size(...)` afterwards, which is the half that does the work.)
 *
 * The chip's own `border`/`padding` stay on the inner `Text`, so it is drawn and sized exactly as before — but the
 * LABEL is now 48 dp wide in the title `Row`, and that is not free. It is the unweighted child, measured first, so a
 * long score title ellipsizes about 20 dp earlier than it did, and the visible gap between title and chip grows from
 * the 8 dp `Spacer` to roughly 18 dp as the chip centers in its box. Nothing moves vertically (48 dp fits inside
 * `TopAppBar`'s 64 dp container) and nothing clips. That trade is deliberate: a reachable escape hatch after "Don't
 * show again" is worth 20 dp of title. The ripple is circular and fills the target, matching the `IconButton`s
 * beside it.
 */
@Composable
private fun ReaderPdfLabel(onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .defaultMinSize(minWidth = 48.dp, minHeight = 48.dp)
            .clip(CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = "PDF",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(4.dp))
                .padding(horizontal = 6.dp, vertical = 1.dp),
        )
    }
}

@Composable
private fun ReadyScore(
    state: ReaderState.Ready,
    scoreHandle: Long?,
    fontProvider: io.github.jiyimeta.sheetmusic.compose.render.FontProvider,
    audioVm: ReaderAudioViewModel,
    layoutOptions: LayoutOptions,
    bottomContentPad: Dp = 0.dp,
    /** Annotation layers + capture pipeline, owned by ReaderScreen. Null ⇒ no annotation on this surface. */
    annotation: AnnotationSurfaceState? = null,
    /** User opt-out for continuous-playback auto-scroll (SettingsPrefs `autoFollow` / the display
     * inspector row). See [shouldAutoFollow]. */
    autoFollowEnabled: Boolean = true,
) {
    val page = state.program.pages.first()
    // Armed only when a surface state was passed AND its tool is out; every gesture gate below reads
    // this rather than the nullable bundle.
    val annotationMode = annotation?.annotationMode == true

    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    // Held as the state object, not just through the `by` delegate, so the score surface's
    // `graphicsLayer` block can read it during the LAYER phase rather than capturing a composed value —
    // see `scoreSurfaceModifier` below for why that distinction is what makes a pinch cheap.
    val scaleState = remember { mutableFloatStateOf(1f) }
    var scale by scaleState
    // The zoom the score's bands were last RECORDED at, as opposed to `scale`, which is where the
    // fingers are right now. Splitting the two is what keeps a pinch off the re-record path: `pxPerMM`
    // feeds band geometry and glyph rasterisation, so following the live scale re-records all of the
    // score's draw commands every frame of the gesture. Instead the bands stay recorded at
    // `rasterScale`, a layer transform covers the difference while the fingers are down, and the one
    // real re-raster happens when they lift.
    val rasterScaleState = remember { mutableFloatStateOf(1f) }
    var rasterScale by rasterScaleState
    // Drives AnnotationDryOverlay's reflow-recompute gate (skip recompute mid-stroke). MVP leaves
    // this always false and relies on the dry overlay's own recompute-on-`drawings`-change instead —
    // flipping it true for the duration of an active wet stroke (via the wet overlay's own
    // start/finish callbacks, which aren't exposed yet) is a future refinement, not required for MVP.
    val isDrawing = false

    val vScroll = rememberScrollState()
    val hScroll = rememberScrollState()
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()

    // Fixed-density render: pxPerMM is the same on every device, so the staff is the same on-screen
    // size on phone and tablet. The engine reflows to the viewport width (reported below) so a wider
    // screen shows MORE music, not bigger notes. Pinch `scale` multiplies on top. (iOS parity.)
    val fitPxPerMM = if (viewportSize.width > 0) fixedPxPerMm(density.density) else 0f

    // Wet→dry ink handoff: androidx.ink keeps drawing a finished stroke until we remove it, so hold that
    // removal until the dry overlay has painted the committed stroke — otherwise the ink blinks out at
    // finger-up for the whole asynchronous commit. A retained copy is frozen at the transform captured when
    // the stroke finished, so a camera change retires it: a brief blink beats a stroke sitting at the old
    // zoom over a rescaled score. [inkHandoff] itself is a parameter now (hoisted to ReaderScreen — its
    // declaration site there explains why), but this camera-retire watch stays here since it needs the
    // local `scale` state. Watched through snapshotFlow rather than as LaunchedEffect keys: `scale`
    // changes every frame of a pinch, and keying on it would cancel and relaunch the effect just as often.
    LaunchedEffect(Unit) {
        snapshotFlow { scale }.drop(1).collect { annotation?.inkHandoff?.releaseAll() }
    }

    // The layout width is reported by ReaderScreen's content Box (composed for every state), so the
    // engine has it before the first layout — `viewportSize` here is only for scroll / zoom / tap math.
    val contentWidthPx = (page.widthMM.toFloat() * fitPxPerMM * scale)
    val contentHeightPx = (page.heightMM.toFloat() * fitPxPerMM * scale)
    val isZoomed = contentWidthPx > viewportSize.width + 0.5f

    // Vertical breathing room so the first/last system isn't flush. Tunable.
    val vPadPx = with(density) { 16.dp.toPx() }
    val padPx = with(density) { 24.dp.toPx() }
    // Extra bottom padding (added below `vPadPx`) so the last system can scroll out from under the
    // floating play FAB when the seek bar is off. Top stays `vPadPx`, so cursor / tap math is unchanged.
    val bottomPadPx = with(density) { bottomContentPad.toPx() }

    // Auto-scroll: keep the playback cursor in view via the shared Domain keep-in-view math (JNI).
    // Vertical: pin the playing system to the top when the lookahead anchor is set (playing), falling
    // back to gentle keep-in-view when paused / on a manual seek (anchor == null). Horizontal: always
    // follows the real cursor when zoomed. `autoFollowEnabled` is a key so a mid-playback toggle flip
    // re-arms / disarms follow promptly instead of lagging until an unrelated restart.
    LaunchedEffect(scoreHandle, fitPxPerMM, scale, autoFollowEnabled) {
        val handle = scoreHandle ?: return@LaunchedEffect
        if (fitPxPerMM <= 0f) return@LaunchedEffect
        combine(audioVm.currentCursor, audioVm.scrollAnchorCursor) { real, anchor -> real to anchor }
            .collectLatest { (real, anchor) ->
                if (real == null) return@collectLatest
                val isPlaying = anchor != null
                // Auto-follow opt-out (parity: iOS `readerAutoFollowEnabled`): off means no re-pin
                // during playback AND no recenter-on-pause — full manual viewport control.
                if (!autoFollowEnabled) return@collectLatest
                // Suspend just the playing re-pin while auto-follow is suspended — i.e. the reader took
                // manual control of the viewport during playback (sticky until play/seek, Task 5). The
                // paused/manual keep-in-view branch below still runs — a gesture there is the reader
                // positioning the view themselves, not something to fight.
                if (isPlaying &&
                    !shouldAutoFollow(autoFollowEnabled, isPlaying, audioVm.isPlaybackFollowSuspended.value)
                ) {
                    return@collectLatest
                }
                val realBytes = SheetMusicJNI.nativeCursorFrame(handle, ScoreCursorCodec.encode(real))
                if (realBytes.isEmpty()) return@collectLatest
                val realFrame = DecodedFrameCodec.decode(realBytes)
                val realYMin = (vPadPx + realFrame.y * fitPxPerMM * scale).toDouble()
                val realYMax = (vPadPx + (realFrame.y + realFrame.height) * fitPxPerMM * scale).toDouble()

                val newY = if (anchor != null) {
                    // Playing: pin the playing system to the top, triggered by the lookahead/playing
                    // system leaving the viewport. topInset = vPadPx clears the (already-inset) top bar.
                    val anchorBytes = SheetMusicJNI.nativeCursorFrame(handle, ScoreCursorCodec.encode(anchor))
                    val lookaheadYMax = if (anchorBytes.isNotEmpty()) {
                        val af = DecodedFrameCodec.decode(anchorBytes)
                        (vPadPx + (af.y + af.height) * fitPxPerMM * scale).toDouble()
                    } else {
                        realYMax
                    }
                    FolinoReaderJNI.nativeScrollOffsetPinningSystemTop(
                        vScroll.value.toDouble(),
                        realYMin,
                        realYMax,
                        lookaheadYMax,
                        viewportSize.height.toDouble(),
                        vPadPx.toDouble(),
                    ).toFloat()
                } else {
                    // Paused / manual seek: gentle keep-in-view (existing behavior).
                    FolinoReaderJNI.nativeScrollOffsetKeepingInView(
                        vScroll.value.toDouble(),
                        realYMin,
                        realYMax,
                        viewportSize.height.toDouble(),
                        padPx.toDouble(),
                    ).toFloat()
                }
                if (abs(newY - vScroll.value) >= 0.5f) {
                    vScroll.animateScrollTo(newY.toInt().coerceAtLeast(0))
                }

                if (isZoomed) {
                    val xMin = (realFrame.x * fitPxPerMM * scale)
                    val xMax = ((realFrame.x + realFrame.width) * fitPxPerMM * scale)
                    val newX = FolinoReaderJNI.nativeScrollOffsetKeepingInView(
                        hScroll.value.toDouble(),
                        xMin,
                        xMax,
                        viewportSize.width.toDouble(),
                        padPx.toDouble(),
                    ).toFloat()
                    if (abs(newX - hScroll.value) >= 0.5f) {
                        hScroll.animateScrollTo(newX.toInt().coerceAtLeast(0))
                    }
                }
            }
    }

    Box(
        Modifier
            .fillMaxSize()
            .onSizeChanged { viewportSize = it }
            // Tap-to-seek + audition. Lives in its own pointerInput so it coexists with the pinch
            // detector below: detectTapGestures only fires on a tap (a down+up with no drag), while
            // the pinch loop consumes two-finger moves — neither steals the other's events. The tap
            // point is in this outer (viewport) px space; fold the scroll offsets and the fixed
            // vertical padding into the content offset so the helper's divide yields document-mm.
            // Disabled while annotating: a single-finger tap there is the wet overlay's to consume
            // (a stroke or an annotation dot), not a seek.
            .pointerInput(scoreHandle, fitPxPerMM, layoutOptions, annotationMode) {
                if (annotationMode) return@pointerInput
                val handle = scoreHandle ?: return@pointerInput
                if (fitPxPerMM <= 0f) return@pointerInput
                val optionsBytes = layoutOptions.encode()
                detectTapGestures { offset ->
                    val cursor = nearestCursorForTap(
                        tap = offset,
                        contentOffsetPx = Offset(-hScroll.value.toFloat(), vPadPx - vScroll.value.toFloat()),
                        pxPerMM = fitPxPerMM,
                        scale = scale,
                        scoreHandle = handle,
                        layoutOptionsBytes = optionsBytes,
                    ) ?: return@detectTapGestures
                    audioVm.handleTap(cursor)
                }
            }
            // Pinch zoom: only two-finger gestures are consumed here; single-finger
            // drags fall through to the scroll modifiers (native fling + overscroll).
            .pointerInput(fitPxPerMM) {
                if (fitPxPerMM <= 0f) return@pointerInput
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    do {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        val pressed = event.changes.count { it.pressed }
                        if (pressed >= 2) {
                            // A live two-finger contact suspends playback auto-follow (Task 5), even
                            // before any actual zoom delta — `scrollState.isScrollInProgress` alone
                            // would miss a pinch, since two fingers holding steady on the score never
                            // register as a scroll gesture. Sticky: it persists past the gesture end and
                            // is cleared only on play/seek (see `isPlaybackFollowSuspended`).
                            audioVm.suspendPlaybackFollowForManualViewportChange()
                            val zoom = event.calculateZoom()
                            if (zoom != 1f) {
                                val centroid = event.calculateCentroid(useCurrent = true)
                                val newScale = (scale * zoom).coerceIn(1f, 8f)
                                val ratio = newScale / scale
                                if (ratio != 1f && !centroid.x.isNaN() && !centroid.y.isNaN()) {
                                    val newX = focalAdjustedOffset(hScroll.value.toFloat(), centroid.x, ratio)
                                    val newY = focalAdjustedOffset(vScroll.value.toFloat(), centroid.y, ratio, vPadPx)
                                    scale = newScale
                                    // scrollTo is a suspend fun; PointerInputScope is a restricted
                                    // coroutine scope that doesn't allow arbitrary launches. Use the
                                    // composable-level scope (from rememberCoroutineScope) instead.
                                    scope.launch { hScroll.scrollTo(newX.toInt().coerceAtLeast(0)) }
                                    scope.launch { vScroll.scrollTo(newY.toInt().coerceAtLeast(0)) }
                                }
                                event.changes.forEach { if (it.positionChanged()) it.consume() }
                            }
                        }
                    } while (event.changes.any { it.pressed })
                    // Fingers up: re-record the score at the zoom it is now being shown at, which also
                    // returns the surface's layer transform to identity. Until this runs the bands are
                    // a scaled copy of their last recording — sharp enough mid-gesture, since a layer
                    // transform still scales vector ops rather than a bitmap, but the glyphs were
                    // rasterised for the old size. Skipped when the scale did not move, so an ordinary
                    // tap or scroll gesture costs nothing here.
                    if (rasterScaleState.floatValue != scaleState.floatValue) {
                        rasterScaleState.floatValue = scaleState.floatValue
                    }
                }
            }
            // Sticky playback-follow suspension (Task 5) — fired ONLY by a real single-finger DRAG.
            // Observes on the Initial pass and NEVER consumes, so the vertical/horizontal scroll
            // modifiers below still get the gesture (native fling + overscroll). Firing on real pointer
            // MOVEMENT — not `ScrollableState.isScrollInProgress` — is the whole fix: the auto-follow
            // re-pin drives `animateScrollTo`, which flips `isScrollInProgress` true WITHOUT any pointer
            // event, so the old snapshotFlow trigger mistook the auto-scroll's own re-pin for a manual
            // gesture and latched suspension permanently OFF. A programmatic scroll emits no pointer
            // input, so this detector never self-suspends (mirrors Page mode's `DragInteraction.Start`).
            // A pure tap (down+up, no move) is a seek — requiring `positionChanged` skips it; two-finger
            // contact is the pinch detector's job above. Sticky: cleared only on play/seek (see
            // `ReaderAudioViewModel.isPlaybackFollowSuspended`); `suspend…()` is a no-op when not playing.
            .pointerInput(audioVm) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    var suspended = false
                    do {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        if (!suspended && event.changes.any { it.pressed && it.positionChanged() }) {
                            audioVm.suspendPlaybackFollowForManualViewportChange()
                            suspended = true
                        }
                    } while (event.changes.any { it.pressed })
                }
            },
        contentAlignment = Alignment.TopStart,
    ) {
        // Scroll modifiers: vertical always; horizontal only when zoomed so that
        // at fit-width there is zero horizontal interaction (no horizontal stretch). While annotating,
        // scrolling is off entirely — the wet overlay above consumes the single-finger drag as a
        // stroke instead; a 2-finger gesture still reaches the pinch pointerInput (a separate,
        // always-installed handler) so pan/zoom keeps working mid-annotation.
        //
        // Annotation turns the gesture OFF via `enabled = false` rather than dropping to a bare
        // `Modifier`. Dropping the modifier also drops what it brings besides the gesture: the scroll
        // offset (the score would jump back to its top the moment the pencil is armed) and — the
        // expensive part — the `placeRelativeWithLayer` that gives the scrolled content its own
        // RenderNode. Without that layer every wet-ink frame invalidates all the way up to the root
        // and re-records the whole score's display list, which is what made drawing crawl on long
        // scores. `enabled = false` keeps both and still consumes no drags.
        val scrollEnabled = !annotationMode
        val scrollModifier = if (isZoomed) {
            Modifier
                .verticalScroll(vScroll, enabled = scrollEnabled)
                .horizontalScroll(hScroll, enabled = scrollEnabled)
        } else {
            Modifier.verticalScroll(vScroll, enabled = scrollEnabled)
        }

        Box(scrollModifier) {
            Box(
                Modifier.size(
                    width = with(density) { contentWidthPx.toDp() },
                    // `bottomPadPx` extends the scrollable extent below the page (top-anchored content),
                    // so scrolling to the end reveals empty space tall enough to clear the floating FAB.
                    height = with(density) { (contentHeightPx + vPadPx * 2 + bottomPadPx).toDp() },
                ),
            ) {
                // Remembered as one object rather than rebuilt per composition, and reading the two
                // scales INSIDE the `graphicsLayer` block rather than outside it. Both matter, for the
                // same reason: a pinch changes `scale` every frame, which recomposes this function, and
                // a fresh modifier instance would make `BandedScorePage` un-skippable — every band would
                // recompose, its `drawBehind` lambda would be replaced, and the whole score would
                // re-record. Kept stable, the bands are skipped entirely and the gesture only updates
                // this one layer's transform. `transformOrigin` is the top-left because the score is
                // drawn from the surface's origin, matching how the content box grows.
                val scoreSurfaceModifier = remember(vPadPx, density) {
                    Modifier
                        .fillMaxSize()
                        .padding(vertical = with(density) { vPadPx.toDp() })
                        .graphicsLayer {
                            val zoom = scaleState.floatValue / rasterScaleState.floatValue
                            scaleX = zoom
                            scaleY = zoom
                            transformOrigin = TransformOrigin(0f, 0f)
                        }
                }
                // Banded, not plain `ScorePage`: the vertical layout is ONE page as tall as the whole
                // document, so a single Canvas would put every command of the score in one display list.
                // Scrolling does not re-record that list (a scroll container places its content with its
                // own layer), but the renderer still walks and rejects every op each frame — tens of
                // thousands of them on a long score. `BandedScorePage` slices the page and gives each
                // band its own layer, so off-screen bands are rejected once by their bounds.
                //
                // It also stops the overlays below from dragging the score into their re-records: while
                // the score shared the scroll container's layer, every playback-cursor tick (~30/s),
                // every ink frame, and every A–B marker change re-recorded all of the score's commands.
                // Deliberately NOT wrapped in a `graphicsLayer` here — that would collapse the bands back
                // into one layer and undo both effects.
                //
                // `fillMaxSize` (not `fillMaxWidth`): a Compose `Canvas` is a `Spacer`, so it only takes
                // a dimension the constraints FIX. Under `fillMaxWidth` the score surface was the full
                // content width but only `vPadPx * 2` tall and painted everything outside its own bounds,
                // which leaves a layer nothing useful to cull against.
                BandedScorePage(
                    page = page,
                    fontProvider = fontProvider,
                    // `rasterScale`, not `scale` — this only moves when a pinch ends, so the bands are
                    // recorded once per gesture instead of once per frame.
                    pxPerMM = fitPxPerMM * rasterScale,
                    modifier = scoreSurfaceModifier,
                )
                val abAccent = MaterialTheme.colorScheme.primary
                val aPending by audioVm.repeatPendingA.collectAsStateWithLifecycle()
                val bPending by audioVm.repeatPendingB.collectAsStateWithLifecycle()
                val repeatMode by audioVm.repeatMode.collectAsStateWithLifecycle()
                scoreHandle?.let { handle ->
                    PlaybackCursorOverlay(
                        scoreHandle = handle,
                        cursorFlow = audioVm.currentCursor,
                        pxPerMM = fitPxPerMM,
                        scale = scale,
                        panOffset = Offset.Zero,
                        color = abAccent.copy(alpha = ON_SCREEN_CURSOR_ALPHA),
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(vertical = with(density) { vPadPx.toDp() }),
                    )
                    // Loop region highlight only in A–B loop mode. Whole-piece repeat (LOOP_ALL) loops
                    // the entire score, so highlighting it would tint the whole page — suppress it
                    // there (iOS parity: the loop overlay is gated on `mode == .abLoop`).
                    if (repeatMode == RepeatMode.AB_LOOP) {
                        LoopHighlightOverlay(
                            scoreHandle = handle,
                            loopRangeFlow = audioVm.loopRange,
                            pxPerMM = fitPxPerMM,
                            scale = scale,
                            panOffset = Offset.Zero,
                            color = abAccent.copy(alpha = 0.15f),
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(vertical = with(density) { vPadPx.toDp() }),
                        )
                    }
                    AbBoundaryMarkersOverlay(
                        scoreHandle = handle,
                        aMeasure = aPending,
                        bMeasure = bPending,
                        pxPerMM = fitPxPerMM,
                        scale = scale,
                        panOffset = Offset.Zero,
                        color = abAccent,
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(vertical = with(density) { vPadPx.toDp() }),
                    )
                    annotation?.let { an ->
                        // The dry layer keeps the same padding as the sibling overlays above, so
                        // document y=0 already lands at the View's y=0 and its pan offset is zero.
                        //
                        // The wet window is pinned to the visible band by offsetting it by the scroll
                        // position, and `worldToScreen` folds that same offset in (plus the vPad the
                        // siblings get from their padding) so document coordinates land exactly where the
                        // dry layer paints them. Reading `vScroll.value` during composition is safe here
                        // precisely because this layer only exists while annotating, and annotating
                        // disables scrolling — the value cannot change under us mid-session.
                        val wetWindowTopPx = vScroll.value
                        val wetWindowHeightPx = viewportSize.height.coerceAtLeast(0)
                        AnnotationLayers(
                            resolveDisplayTransforms = remember(handle) { musicalDisplayTransformsResolver(handle) },
                            annotation = an,
                            pxPerMM = fitPxPerMM,
                            scale = scale,
                            isDrawing = isDrawing,
                            dryPanOffset = Offset.Zero,
                            dryModifier = Modifier
                                .fillMaxSize()
                                .padding(vertical = with(density) { vPadPx.toDp() }),
                            wetWorldToScreen = remember(fitPxPerMM, scale, wetWindowTopPx, vPadPx) {
                                android.graphics.Matrix().apply {
                                    setScale(fitPxPerMM * scale, fitPxPerMM * scale)
                                    postTranslate(0f, vPadPx - wetWindowTopPx)
                                }
                            },
                            wetModifier = Modifier
                                .fillMaxWidth()
                                .height(with(density) { wetWindowHeightPx.toDp() })
                                .offset { IntOffset(0, wetWindowTopPx) },
                        )
                    }
                }
            }
        }
    }
}

/**
 * New scroll offset (px) that keeps the content point under the pinch centroid
 * fixed across a zoom step of ratio `r = newScale / oldScale`. Only the page
 * content scales by `r`; a constant leading [pad] (the fixed vertical padding
 * above the page, which does NOT scale with zoom) is held out of the scaling.
 * In scroll space the content point under the centroid is at
 * `scroll + centroid`; the scaling page part is `scroll + centroid - pad`, so
 * after scaling by `r` the new offset is
 * `pad + r * (scroll - pad + centroid) - centroid`. With `pad = 0` this reduces
 * to the simple `r * (scroll + centroid) - centroid`. The scroll state clamps
 * the result to `[0, maxValue]`, so no clamp is needed here.
 */
private fun focalAdjustedOffset(
    currentScroll: Float,
    centroid: Float,
    ratio: Float,
    pad: Float = 0f,
): Float = pad + ratio * (currentScroll - pad + centroid) - centroid

/**
 * Builds the musical [AnnotationDryOverlay]/[AnnotationLayers] `resolveDisplayTransforms` lambda for
 * [scoreHandle]: the ssm ref-point round trip (`SheetMusicJNI.nativeAnchorReferencePoint`) followed by
 * `ReaderAnnotationJNI.displayTransforms`, exactly what this composable's own `computePlacement` did
 * inline before Task 11 generalized the seam to also serve a PDF page-anchor resolver (see
 * [AnnotationDryOverlay]'s parameter doc). Shared by `ReadyScore` and `PagedScore` — both `remember` the
 * result keyed on their own `scoreHandle`, so the lambda's identity (and so the dry overlay's
 * `LaunchedEffect`) only changes when the handle itself does, never on a live pinch frame.
 */
internal fun musicalDisplayTransformsResolver(
    scoreHandle: Long,
): (List<DrawingAnchorWire>) -> ByteArray = { drawings ->
    val identities = drawings.map {
        ResolvedAnchorWire(
            it.measureIndex, it.tickInMeasure, it.partIndex, it.staffIndexInPart, it.dxSp, it.verticalOffsetSp,
        )
    }
    val refBytes = SheetMusicJNI.nativeAnchorReferencePoint(
        scoreHandle,
        encodeWireArray(identities, ResolvedAnchorWireCodec::encodePayload),
    )
    if (refBytes.isEmpty()) {
        ByteArray(0)
    } else {
        ReaderAnnotationJNI.displayTransforms(
            encodeWireArray(drawings, DrawingAnchorWireCodec::encodePayload),
            refBytes,
        )
    }
}

@Composable
private fun TransportBar(
    audioVm: ReaderAudioViewModel,
    /** Whether this session may play at all right now (`ReaderCapabilities.canPlayNow`, over JNI) — a
     * score always, a PDF only once its background OMR parse succeeds. AND'd into [isPrepared] below so
     * a PDF's transport never lights up ahead of a real playable score existing, even if the engine
     * somehow reports a non-STOPPED playback state. */
    enabled: Boolean = true,
    onAnalyticsTransportPrevious: () -> Unit = {},
    onAnalyticsTransportNext: () -> Unit = {},
    onAnalyticsSeek: () -> Unit = {},
) {
    val playback by audioVm.state.collectAsStateWithLifecycle()
    val currentSecs by audioVm.currentTimeSeconds.collectAsStateWithLifecycle()
    val totalSecs by audioVm.totalTimeSeconds.collectAsStateWithLifecycle()
    val engine by audioVm.engine.collectAsStateWithLifecycle()
    val repeatMode by audioVm.repeatMode.collectAsStateWithLifecycle()
    val aMarked by audioVm.repeatPendingA.collectAsStateWithLifecycle()
    val bMarked by audioVm.repeatPendingB.collectAsStateWithLifecycle()

    val isPrepared = enabled && playback != PlaybackState.STOPPED && playback != PlaybackState.EXPORTING

    Column(
        Modifier
            .fillMaxWidth()
            // Keep the bar clear of the gesture / navigation bar at the bottom of the screen.
            .navigationBarsPadding()
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        val marks by audioVm.rehearsalMarks.collectAsStateWithLifecycle()
        val liveFraction = if (totalSecs > 0) (currentSecs / totalSecs).toFloat().coerceIn(0f, 1f) else 0f
        // While the user scrubs the rehearsal-mark row, the snapped mark is previewed on the seek bar
        // (仮 seek); the real engine seek fires only on release. Null when not scrubbing the row.
        var rehearsalPreview by remember { mutableStateOf<Float?>(null) }
        // Rehearsal-mark pills above the seek bar; tap or drag (snapping to the nearest mark) to jump to
        // a section. The row collapses to nothing when the score carries no marks. Positions/cursors
        // come from the shared Swift side.
        RehearsalMarkBubbleRow(
            marks = marks,
            currentFraction = liveFraction,
            enabled = isPrepared,
            onSeek = { cursor ->
                if (isPrepared) {
                    // A rehearsal-mark jump is a manual cursor set → resume auto-follow (Task 5).
                    audioVm.resumePlaybackFollow()
                    engine?.seek(to = cursor)
                }
            },
            onPreview = { rehearsalPreview = it },
            modifier = Modifier.fillMaxWidth(),
        )
        // Thumbless YouTube-Music-style seek bar; thickens while scrubbing. Shows the rehearsal-row
        // drag preview when scrubbing the marks, otherwise the live playback position.
        ReaderSeekBar(
            fraction = rehearsalPreview ?: liveFraction,
            enabled = isPrepared,
            onSeek = { fraction ->
                if (totalSecs > 0) {
                    // A seek-bar scrub is a manual cursor set → resume auto-follow so the score follows the
                    // committed position instead of staying suspended (Task 5; iOS `endScrub`).
                    audioVm.resumePlaybackFollow()
                    engine?.seek(fraction * totalSecs)
                }
            },
            // Analytics: count one seek per deliberate scrub COMMIT (drag release), not per drag frame.
            onSeekCommit = onAnalyticsSeek,
            modifier = Modifier.fillMaxWidth(),
        )
        // Transport row with the time readout OVERLAID on its top band rather than stacked above it
        // in the Column (iOS's `.overlay` idiom). The readout occupies a fixed [timeRowHeight] band
        // 4dp below the seek bar; the larger transport buttons are bottom-aligned so they rise only
        // [buttonTimeOverlap] into that band — a slight, controlled intrusion. The leading readout
        // (current time) overlaps the top of jump-to-start; play/pause is centered, clear of the
        // edge readouts.
        Box(
            Modifier
                .fillMaxWidth()
                .padding(top = 4.dp)
                .height(timeRowHeight + transportButtonSize - buttonTimeOverlap),
        ) {
            Row(
                Modifier.fillMaxWidth().align(Alignment.TopCenter).height(timeRowHeight),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = formatTime(currentSecs),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    text = formatTime(totalSecs),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            // jump-to-start: no circle, but the same icon size and tap target as play/pause. Pinned
            // to the leading edge (the prev/next-measure buttons live in the centered cluster below).
            IconButton(
                onClick = {
                    if (isPrepared) {
                        // Jump-to-start is a manual cursor set → resume auto-follow (Task 5).
                        audioVm.resumePlaybackFollow()
                        engine?.seek(0.0)
                        onAnalyticsSeek()
                    }
                },
                enabled = isPrepared,
                modifier = Modifier.align(Alignment.BottomStart).size(transportButtonSize),
            ) {
                Icon(
                    Icons.Default.SkipPrevious,
                    contentDescription = "Jump to start",
                    modifier = Modifier.size(transportIconSize),
                )
            }
            // Centered cluster: previous-measure, play/pause (primary), next-measure. Jump-to-start
            // stays pinned to the leading edge. `‹` / `›` step exactly one measure via the shared
            // Score.cursorSteppingMeasure logic on the Swift side (restart-vs-previous idiom included).
            Row(
                Modifier.align(Alignment.BottomCenter),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                IconButton(
                    onClick = {
                        audioVm.stepMeasureBackward()
                        onAnalyticsTransportPrevious()
                    },
                    enabled = isPrepared,
                    modifier = Modifier.size(measureStepButtonSize),
                ) {
                    Icon(
                        Icons.Default.NavigateBefore,
                        contentDescription = "Previous measure",
                        modifier = Modifier.size(measureStepIconSize),
                    )
                }
                // play/pause: filled circular button, primary control.
                FilledIconButton(
                    onClick = {
                        if (playback == PlaybackState.PLAYING) engine?.pause() else engine?.play()
                    },
                    enabled = isPrepared,
                    modifier = Modifier.size(transportButtonSize),
                ) {
                    if (playback == PlaybackState.PLAYING) {
                        Icon(
                            Icons.Default.Pause,
                            contentDescription = "Pause",
                            modifier = Modifier.size(transportIconSize),
                        )
                    } else {
                        Icon(
                            Icons.Default.PlayArrow,
                            contentDescription = "Play",
                            modifier = Modifier.size(transportIconSize),
                        )
                    }
                }
                IconButton(
                    onClick = {
                        audioVm.stepMeasureForward()
                        onAnalyticsTransportNext()
                    },
                    enabled = isPrepared,
                    modifier = Modifier.size(measureStepButtonSize),
                ) {
                    Icon(
                        Icons.Default.NavigateNext,
                        contentDescription = "Next measure",
                        modifier = Modifier.size(measureStepIconSize),
                    )
                }
            }
            // A/B endpoint pill: trailing edge, only in A–B loop mode (mirroring iOS placement).
            if (repeatMode == RepeatMode.AB_LOOP) {
                AbEndpointButtons(
                    aSet = aMarked != null,
                    bSet = bMarked != null,
                    enabled = isPrepared,
                    onSetA = { audioVm.setRepeatA() },
                    onSetB = { audioVm.setRepeatB() },
                    modifier = Modifier.align(Alignment.BottomEnd),
                )
            }
        }
    }
}

/** Tap target / circle size for the ON-state transport buttons (play/pause + jump-to-start). Larger
 * than the Material default so the controls read as the primary action and rise into the overlaid
 * time-readout band above them. */
private val transportButtonSize = 56.dp

/** Glyph size inside [transportButtonSize] buttons — shared by play/pause and jump-to-start so the
 * two read as the same control family (only the filled circle distinguishes play/pause). */
private val transportIconSize = 30.dp

/** Height of the overlaid time-readout band between the seek bar and the transport buttons. */
private val timeRowHeight = 18.dp

/** How far the (bottom-aligned) transport buttons rise into the time-readout band above them — a
 * slight intrusion so the controls sit close to the readout without a full empty row between. */
private val buttonTimeOverlap = 4.dp

/** Tap target for the secondary measure-skip buttons (`‹` / `›`) flanking play/pause — smaller than
 * [transportButtonSize] so play/pause stays the dominant control. */
private val measureStepButtonSize = 44.dp

/** Glyph size inside the measure-skip buttons. */
private val measureStepIconSize = 28.dp

/** Height of the rehearsal-mark pill row above the seek bar. */
private val rehearsalBubbleRowHeight = 28.dp

/**
 * Thumbless seek bar in the YouTube-Music idiom: a thin rounded track (filled active portion over a
 * lighter inactive remainder) with no draggable thumb, which thickens while the user scrubs. Tap or
 * horizontal drag anywhere along the bar seeks. The row is a fixed height equal to the thickened
 * track, so the active portion's bottom edge stays put and the 4dp gap to the time readout below
 * does not shift as the bar grows. iOS has its own custom SeekBar; this mirrors that intent rather
 * than using a Material thumb slider.
 *
 * @param fraction current playback position, 0..1.
 * @param onSeek invoked with the new 0..1 fraction on tap and on each drag move.
 * @param onSeekCommit invoked once when a scrub is committed (drag release) — for analytics, so a
 *   deliberate seek counts once rather than per drag frame. Not called for every [onSeek] move.
 */
@Composable
private fun ReaderSeekBar(
    fraction: Float,
    enabled: Boolean,
    onSeek: (Float) -> Unit,
    onSeekCommit: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    var dragging by remember { mutableStateOf(false) }
    var dragFraction by remember { mutableFloatStateOf(0f) }
    // While scrubbing, follow the finger (dragFraction) instead of the live playback fraction, so
    // the bar doesn't fight engine-seek latency.
    val shown = (if (dragging) dragFraction else fraction).coerceIn(0f, 1f)

    val activeHeight = 8.dp
    val trackThickness by animateDpAsState(
        targetValue = if (dragging) activeHeight else 4.dp,
        label = "seekTrackThickness",
    )

    val activeColor =
        if (enabled) MaterialTheme.colorScheme.primary
        else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
    val inactiveColor = MaterialTheme.colorScheme.surfaceVariant

    Canvas(
        modifier
            .fillMaxWidth()
            .height(activeHeight)
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                detectTapGestures { offset ->
                    onSeek((offset.x / size.width).coerceIn(0f, 1f))
                }
            }
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                detectHorizontalDragGestures(
                    onDragStart = { offset ->
                        dragging = true
                        dragFraction = (offset.x / size.width).coerceIn(0f, 1f)
                        onSeek(dragFraction)
                    },
                    onDragEnd = {
                        dragging = false
                        onSeekCommit()
                    },
                    onDragCancel = { dragging = false },
                    onHorizontalDrag = { change, _ ->
                        dragFraction = (change.position.x / size.width).coerceIn(0f, 1f)
                        onSeek(dragFraction)
                    },
                )
            },
    ) {
        val centerY = size.height / 2f
        val stroke = trackThickness.toPx()
        drawLine(
            color = inactiveColor,
            start = Offset(0f, centerY),
            end = Offset(size.width, centerY),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        if (shown > 0f) {
            drawLine(
                color = activeColor,
                start = Offset(0f, centerY),
                end = Offset(size.width * shown, centerY),
                strokeWidth = stroke,
                cap = StrokeCap.Round,
            )
        }
    }
}

/**
 * Row of rehearsal-mark pills laid out above the seek bar, each horizontally centered on its mark's
 * notated-time [RehearsalMarkEntry.fraction]. The highlighted pill (filled primary container, drawn
 * frontmost) is the drag target while scrubbing, otherwise the mark at or before the live playback
 * position.
 *
 * Interaction (whole-row, like the seek bar): a tap seeks to the nearest mark. A horizontal drag is a
 * DISCRETE scrub — it snaps to the nearest mark as the finger moves and previews that position on the
 * seek bar via [onPreview] (仮 seek), committing the real engine seek through [onSeek] only on release.
 *
 * Renders nothing when [marks] is empty — positions/cursors are computed on the Swift side (shared
 * `Score.rehearsalMarks()`); this only lays out, styles, and routes the gesture.
 */
@Composable
private fun RehearsalMarkBubbleRow(
    marks: List<RehearsalMarkEntry>,
    currentFraction: Float,
    enabled: Boolean,
    onSeek: (ScoreCursor) -> Unit,
    onPreview: (Float?) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (marks.isEmpty()) return
    val density = LocalDensity.current
    // The mark index currently snapped under the finger while dragging; null when not scrubbing.
    var dragIndex by remember { mutableStateOf<Int?>(null) }
    val playbackIndex = marks.indexOfLast { it.fraction.toFloat() <= currentFraction }
    val highlightIndex = dragIndex ?: playbackIndex

    fun nearestIndex(fraction: Float): Int =
        marks.indices.minByOrNull { abs(marks[it].fraction.toFloat() - fraction) } ?: 0

    BoxWithConstraints(
        modifier
            .height(rehearsalBubbleRowHeight)
            .pointerInput(enabled, marks) {
                if (!enabled) return@pointerInput
                detectTapGestures { offset ->
                    onSeek(marks[nearestIndex((offset.x / size.width).coerceIn(0f, 1f))].cursor)
                }
            }
            .pointerInput(enabled, marks) {
                if (!enabled) return@pointerInput
                detectHorizontalDragGestures(
                    onDragStart = { offset ->
                        val idx = nearestIndex((offset.x / size.width).coerceIn(0f, 1f))
                        dragIndex = idx
                        onPreview(marks[idx].fraction.toFloat())
                    },
                    onHorizontalDrag = { change, _ ->
                        val idx = nearestIndex((change.position.x / size.width).coerceIn(0f, 1f))
                        dragIndex = idx
                        onPreview(marks[idx].fraction.toFloat())
                    },
                    onDragEnd = {
                        dragIndex?.let { onSeek(marks[it].cursor) }
                        dragIndex = null
                        onPreview(null)
                    },
                    onDragCancel = {
                        dragIndex = null
                        onPreview(null)
                    },
                )
            },
    ) {
        val fullWidth = maxWidth
        marks.forEachIndexed { index, mark ->
            // Center the pill BODY on its fraction, clamped so it never spills past either edge. The
            // tail tip still points at the true fraction, so its horizontal position inside the body
            // compensates for the clamp (matching iOS). Width is unknown until first layout, so the
            // body start-anchors and the tail centers for one frame, then both settle.
            var pillWidth by remember(mark) { mutableStateOf(0.dp) }
            val anchor = fullWidth * mark.fraction.toFloat()
            val maxX = (fullWidth - pillWidth).coerceAtLeast(0.dp)
            val x = (anchor - pillWidth / 2).coerceIn(0.dp, maxX)
            val tailFraction =
                if (pillWidth.value > 0f) ((anchor.value - x.value) / pillWidth.value).coerceIn(0f, 1f) else 0.5f
            RehearsalMarkPill(
                text = mark.text,
                isCurrent = index == highlightIndex,
                tailCenterFraction = tailFraction,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .zIndex(if (index == highlightIndex) 1f else 0f)
                    .offset(x = x)
                    .onGloballyPositioned { pillWidth = with(density) { it.size.width.toDp() } },
            )
        }
    }
}

/** Width / height of the downward speech-bubble tail under each rehearsal-mark pill. */
private val rehearsalTailWidth = 9.dp
private val rehearsalTailHeight = 5.dp

/**
 * A single rehearsal-mark pill with a downward speech-bubble tail (iOS parity). The tail tip points at
 * [tailCenterFraction] (0..1 across the body width) so it marks the true timeline position even when the
 * body is clamped to stay on-screen. Filled when current, outlined otherwise.
 */
@Composable
private fun RehearsalMarkPill(
    text: String,
    isCurrent: Boolean,
    tailCenterFraction: Float,
    modifier: Modifier = Modifier,
) {
    val container =
        if (isCurrent) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surface
    val content =
        if (isCurrent) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurfaceVariant
    val density = LocalDensity.current
    val tailW = with(density) { rehearsalTailWidth.toPx() }
    val tailH = with(density) { rehearsalTailHeight.toPx() }
    val cornerPx = with(density) { 8.dp.toPx() }
    val shape = remember(tailCenterFraction, tailW, tailH, cornerPx) {
        GenericShape { size, _ ->
            // ONE continuous outline: a rounded-rect body whose bottom edge detours straight down into
            // the triangle tail and back up, so the body + tail read as a single bubble with no inner
            // seam (mirrors iOS, which strokes a single path). The tip points at [tailCenterFraction].
            val bodyBottom = size.height - tailH
            val r = minOf(cornerPx, bodyBottom / 2f)
            val half = tailW / 2f
            // Keep the tail base on the straight part of the bottom edge (clear of the rounded corners).
            val tip = (tailCenterFraction * size.width)
                .coerceIn(r + half, (size.width - r - half).coerceAtLeast(r + half))
            moveTo(r, 0f)
            lineTo(size.width - r, 0f)
            quadraticBezierTo(size.width, 0f, size.width, r)
            lineTo(size.width, bodyBottom - r)
            quadraticBezierTo(size.width, bodyBottom, size.width - r, bodyBottom)
            lineTo(tip + half, bodyBottom)
            lineTo(tip, size.height)
            lineTo(tip - half, bodyBottom)
            lineTo(r, bodyBottom)
            quadraticBezierTo(0f, bodyBottom, 0f, bodyBottom - r)
            lineTo(0f, r)
            quadraticBezierTo(0f, 0f, r, 0f)
            close()
        }
    }
    Surface(
        color = container,
        contentColor = content,
        shape = shape,
        border = if (isCurrent) null else BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        modifier = modifier,
    ) {
        Text(
            text = text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.labelSmall,
            // Reserve the tail strip below the text so the glyphs stay in the body.
            modifier = Modifier
                .widthIn(max = 96.dp)
                .padding(start = 8.dp, end = 8.dp, top = 2.dp, bottom = 2.dp + rehearsalTailHeight),
        )
    }
}

/**
 * Floating transport cluster shown when the seek bar is hidden (iOS "collapsed/floating" parity,
 * adapted to Android's FAB idiom). A small jump-to-start FAB sits left of the primary play/pause
 * FAB at the bottom-end. Step (prev/next measure) and the rehearsal-mark bar are intentionally
 * not ported. Actions are guarded on the prepared state, matching [TransportBar].
 */
@Composable
fun PlaybackFab(
    audioVm: ReaderAudioViewModel,
    /** See [TransportBar]'s matching parameter — same gate, same reason. */
    enabled: Boolean = true,
    onAnalyticsSeek: () -> Unit = {},
) {
    val playback by audioVm.state.collectAsStateWithLifecycle()
    val engine by audioVm.engine.collectAsStateWithLifecycle()
    val repeatMode by audioVm.repeatMode.collectAsStateWithLifecycle()
    val aMarked by audioVm.repeatPendingA.collectAsStateWithLifecycle()
    val bMarked by audioVm.repeatPendingB.collectAsStateWithLifecycle()
    val isPrepared = enabled && playback != PlaybackState.STOPPED && playback != PlaybackState.EXPORTING

    // FABs have no `enabled` param, so we dim their colors when not prepared to mirror
    // [TransportBar]'s `enabled = isPrepared` affordance (Material disabled-color convention).
    val fabContainerColor =
        if (isPrepared) FloatingActionButtonDefaults.containerColor
        else MaterialTheme.colorScheme.surfaceVariant
    val fabContentColor =
        if (isPrepared) contentColorFor(FloatingActionButtonDefaults.containerColor)
        else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // A/B endpoint pill leads the FAB cluster, only in A–B loop mode.
        if (repeatMode == RepeatMode.AB_LOOP) {
            AbEndpointButtons(
                aSet = aMarked != null,
                bSet = bMarked != null,
                enabled = isPrepared,
                onSetA = { audioVm.setRepeatA() },
                onSetB = { audioVm.setRepeatB() },
            )
        }
        SmallFloatingActionButton(
            onClick = {
                if (isPrepared) {
                    // Jump-to-start is a manual cursor set → resume auto-follow (Task 5).
                    audioVm.resumePlaybackFollow()
                    engine?.seek(0.0)
                    onAnalyticsSeek()
                }
            },
            containerColor = fabContainerColor,
            contentColor = fabContentColor,
        ) {
            Icon(Icons.Default.SkipPrevious, contentDescription = "Jump to start")
        }
        FloatingActionButton(
            onClick = {
                if (isPrepared) {
                    if (playback == PlaybackState.PLAYING) engine?.pause() else engine?.play()
                }
            },
            containerColor = fabContainerColor,
            contentColor = fabContentColor,
        ) {
            if (playback == PlaybackState.PLAYING) {
                Icon(Icons.Default.Pause, contentDescription = "Pause")
            } else {
                Icon(Icons.Default.PlayArrow, contentDescription = "Play")
            }
        }
    }
}

private fun formatTime(seconds: Double): String {
    val s = seconds.coerceAtLeast(0.0)
    val minutes = floor(s / 60).toLong()
    val secs = floor(s % 60).toLong()
    return "%02d:%02d".format(minutes, secs)
}

/**
 * Horizontal scroll surface: the score is laid out as one natural-width row
 * (`ReaderLayoutMode.HORIZONTAL` → the options-aware layout's `.horizontal`
 * branch). Scrolls horizontally always, centers vertically when the single row
 * is shorter than the viewport, and follows the playback cursor measure-by-
 * measure (X parks the measure's leading edge; Y keeps it in view when zoomed
 * taller than the viewport) via the shared Domain math over JNI.
 */
@Composable
internal fun HorizontalScore(
    state: ReaderState.Ready,
    scoreHandle: Long?,
    fontProvider: io.github.jiyimeta.sheetmusic.compose.render.FontProvider,
    audioVm: ReaderAudioViewModel,
    layoutOptions: LayoutOptions,
    pipFit: Boolean = false,
    /** User opt-out for continuous-playback auto-scroll (SettingsPrefs `autoFollow` / the display
     * inspector row). See [shouldAutoFollow]. Defaults true so the PiP surface (which doesn't pass
     * this) keeps following regardless of the main Reader's toggle. */
    autoFollowEnabled: Boolean = true,
    /** Annotation layers + capture pipeline, owned by ReaderScreen. Null on the PiP rendition, which
     * is a passive mirror and must not accept ink. */
    annotation: AnnotationSurfaceState? = null,
) {
    val page = state.program.pages.first()
    val annotationMode = annotation?.annotationMode == true

    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    var scale by remember { mutableFloatStateOf(1f) }

    val vScroll = rememberScrollState()
    val hScroll = rememberScrollState()
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()

    // Fixed-density render (same pxPerMM as vertical) so the single-system row is the same on-screen
    // size on phone and tablet. The row is natural-width (no wrap) → horizontal scroll, and this
    // surface reports no viewport width to the VM (unlike vertical), so the engine's wrap width is moot.
    // In PiP mode, scale instead to fit the system's full height into the window (pipFit = true).
    val verticalPadPx = with(density) { PIP_VERTICAL_PAD.toPx() }
    val fitPxPerMM = when {
        viewportSize.width <= 0 -> 0f
        pipFit -> pipFitPxPerMm(viewportSize.height, verticalPadPx, page.heightMM)
        else -> fixedPxPerMm(density.density)
    }
    val contentWidthPx = (page.widthMM.toFloat() * fitPxPerMM * scale)
    val contentHeightPx = (page.heightMM.toFloat() * fitPxPerMM * scale)

    val padPx = with(density) { 24.dp.toPx() }

    // Vertical scroll only when the zoomed row is taller than the viewport;
    // otherwise it is centered vertically with no vertical interaction.
    val needsVScroll = contentHeightPx > viewportSize.height + 0.5f

    // Auto-scroll: X = measure-anchored leading-edge with lookahead (measure frame + shared
    // Domain fn); Y = keep-in-view, only meaningful when zoomed taller. `autoFollowEnabled` is a key
    // so a mid-playback toggle flip re-arms / disarms follow promptly (parity with ReadyScore).
    LaunchedEffect(scoreHandle, fitPxPerMM, scale, autoFollowEnabled) {
        val handle = scoreHandle ?: return@LaunchedEffect
        if (fitPxPerMM <= 0f) return@LaunchedEffect
        combine(audioVm.currentCursor, audioVm.scrollAnchorCursor) { real, anchor -> real to anchor }
            .collectLatest { (real, anchor) ->
                if (real == null) return@collectLatest
                val isPlaying = anchor != null
                // Auto-follow opt-out (parity: iOS `readerAutoFollowEnabled`): off means no re-pin
                // during playback AND no recenter-on-pause — full manual viewport control.
                if (!autoFollowEnabled) return@collectLatest
                // Suspend just the playing re-pin while auto-follow is suspended (sticky — the reader took
                // manual control of the viewport during playback, Task 5); the paused/manual keep-in-view
                // branches below still run.
                if (isPlaying &&
                    !shouldAutoFollow(autoFollowEnabled, isPlaying, audioVm.isPlaybackFollowSuspended.value)
                ) {
                    return@collectLatest
                }
                val realEnc = ScoreCursorCodec.encode(real)

                val realMBytes = SheetMusicJNI.nativeMeasureFrame(handle, realEnc)
                if (realMBytes.isNotEmpty()) {
                    val rm = DecodedFrameCodec.decode(realMBytes)
                    val realXMin = (rm.x * fitPxPerMM * scale).toDouble()
                    val realXMax = ((rm.x + rm.width) * fitPxPerMM * scale).toDouble()
                    val newX = if (anchor != null) {
                        val lookMBytes = SheetMusicJNI.nativeMeasureFrame(
                            handle, ScoreCursorCodec.encode(anchor),
                        )
                        val lookXMax = if (lookMBytes.isNotEmpty()) {
                            val lm = DecodedFrameCodec.decode(lookMBytes)
                            ((lm.x + lm.width) * fitPxPerMM * scale).toDouble()
                        } else {
                            realXMax
                        }
                        // Axis-agnostic reuse: "system" params carry the playing measure's X-span;
                        // topInset = padPx (left edge inset on the horizontal axis).
                        FolinoReaderJNI.nativeScrollOffsetPinningSystemTop(
                            hScroll.value.toDouble(), realXMin, realXMax, lookXMax,
                            viewportSize.width.toDouble(), padPx.toDouble(),
                        ).toFloat()
                    } else {
                        FolinoReaderJNI.nativeHorizontalMeasureScrollOffset(
                            hScroll.value.toDouble(), realXMin, realXMax,
                            viewportSize.width.toDouble(), padPx.toDouble(),
                        ).toFloat()
                    }
                    if (abs(newX - hScroll.value) >= 0.5f) {
                        hScroll.animateScrollTo(newX.toInt().coerceAtLeast(0))
                    }
                }

                if (needsVScroll) {
                    val cBytes = SheetMusicJNI.nativeCursorFrame(handle, realEnc)
                    if (cBytes.isNotEmpty()) {
                        val f = DecodedFrameCodec.decode(cBytes)
                        val yMin = f.y * fitPxPerMM * scale
                        val yMax = (f.y + f.height) * fitPxPerMM * scale
                        val newY = FolinoReaderJNI.nativeScrollOffsetKeepingInView(
                            vScroll.value.toDouble(),
                            yMin,
                            yMax,
                            viewportSize.height.toDouble(),
                            padPx.toDouble(),
                        ).toFloat()
                        if (abs(newY - vScroll.value) >= 0.5f) {
                            vScroll.animateScrollTo(newY.toInt().coerceAtLeast(0))
                        }
                    }
                }
            }
    }

    Box(
        Modifier
            .fillMaxSize()
            .onSizeChanged { viewportSize = it }
            // Tap-to-seek + audition. Separate pointerInput from the pinch loop (see ReadyScore).
            // The single natural-width row scrolls horizontally always (fold hScroll into x) and
            // is centered vertically when shorter than the viewport (fold that centering offset
            // into y); when zoomed taller it scrolls vertically instead (fold vScroll into y).
            .pointerInput(scoreHandle, fitPxPerMM, layoutOptions, needsVScroll, annotationMode) {
                // While annotating, a tap is the start of a stroke — never a seek.
                if (annotationMode) return@pointerInput
                val handle = scoreHandle ?: return@pointerInput
                if (fitPxPerMM <= 0f) return@pointerInput
                val optionsBytes = layoutOptions.encode()
                detectTapGestures { offset ->
                    val yLead = if (needsVScroll) {
                        -vScroll.value.toFloat()
                    } else {
                        (viewportSize.height - contentHeightPx) / 2f
                    }
                    val cursor = nearestCursorForTap(
                        tap = offset,
                        contentOffsetPx = Offset(-hScroll.value.toFloat(), yLead),
                        pxPerMM = fitPxPerMM,
                        scale = scale,
                        scoreHandle = handle,
                        layoutOptionsBytes = optionsBytes,
                    ) ?: return@detectTapGestures
                    audioVm.handleTap(cursor)
                }
            }
            // Pinch zoom: only two-finger gestures are consumed; single-finger
            // drags fall through to the scroll modifiers (native fling).
            .pointerInput(fitPxPerMM) {
                if (fitPxPerMM <= 0f) return@pointerInput
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    do {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        val pressed = event.changes.count { it.pressed }
                        if (pressed >= 2) {
                            // See [ReadyScore]'s identical comment: a live two-finger contact suspends
                            // auto-follow (Task 5) even before any zoom delta. Sticky until play/seek.
                            audioVm.suspendPlaybackFollowForManualViewportChange()
                            val zoom = event.calculateZoom()
                            if (zoom != 1f) {
                                val centroid = event.calculateCentroid(useCurrent = true)
                                val newScale = (scale * zoom).coerceIn(1f, 8f)
                                val ratio = newScale / scale
                                if (ratio != 1f && !centroid.x.isNaN() && !centroid.y.isNaN()) {
                                    val newX = focalAdjustedOffset(hScroll.value.toFloat(), centroid.x, ratio)
                                    val newY = focalAdjustedOffset(vScroll.value.toFloat(), centroid.y, ratio)
                                    scale = newScale
                                    scope.launch { hScroll.scrollTo(newX.toInt().coerceAtLeast(0)) }
                                    scope.launch { vScroll.scrollTo(newY.toInt().coerceAtLeast(0)) }
                                }
                                event.changes.forEach { if (it.positionChanged()) it.consume() }
                            }
                        }
                    } while (event.changes.any { it.pressed })
                }
            }
            // Sticky playback-follow suspension (Task 5), fired ONLY by a real single-finger DRAG — see
            // the identical detector in [ReadyScore] for the full rationale. Observes on the Initial pass
            // and never consumes, so the horizontal/vertical scroll modifiers below still get the gesture.
            // A programmatic auto-follow re-pin (`animateScrollTo`) emits no pointer input, so unlike the
            // old `isScrollInProgress` snapshotFlow this never self-suspends; a pure tap has no movement so
            // it is skipped; two-finger contact is the pinch detector's job above.
            .pointerInput(audioVm) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    var suspended = false
                    do {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        if (!suspended && event.changes.any { it.pressed && it.positionChanged() }) {
                            audioVm.suspendPlaybackFollowForManualViewportChange()
                            suspended = true
                        }
                    } while (event.changes.any { it.pressed })
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        // Annotating freezes the viewport: a stroke has to stay put under the finger, and the wet
        // window's world→screen matrix is built from the scroll positions read at composition time
        // (see [AnnotationLayers]), which is only sound while they cannot change mid-stroke.
        val scrollEnabled = !annotationMode
        val scrollModifier = if (needsVScroll) {
            Modifier
                .horizontalScroll(hScroll, enabled = scrollEnabled)
                .verticalScroll(vScroll, enabled = scrollEnabled)
        } else {
            Modifier.horizontalScroll(hScroll, enabled = scrollEnabled)
        }

        Box(scrollModifier, contentAlignment = Alignment.Center) {
            // Outer box: full viewport height (when not vertically scrolling) so the
            // short row centers vertically; inner box is the exact scaled page size.
            Box(
                Modifier.size(
                    width = with(density) { contentWidthPx.toDp() },
                    height = with(density) {
                        (if (needsVScroll) {
                            contentHeightPx
                        } else {
                            maxOf(contentHeightPx, viewportSize.height.toFloat())
                        }).toDp()
                    },
                ),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier.size(
                        width = with(density) { contentWidthPx.toDp() },
                        height = with(density) { contentHeightPx.toDp() },
                    ),
                ) {
                    ScorePage(
                        page = page,
                        fontProvider = fontProvider,
                        pxPerMM = fitPxPerMM * scale,
                        // Own RenderNode, for the same reason as the vertical surface above: the cursor
                        // and A–B overlays below are siblings in this Box, and without a layer here each
                        // of their updates re-records the whole row's draw commands.
                        modifier = Modifier.fillMaxSize().graphicsLayer(),
                    )
                    val abAccent = MaterialTheme.colorScheme.primary
                    val aPending by audioVm.repeatPendingA.collectAsStateWithLifecycle()
                    val bPending by audioVm.repeatPendingB.collectAsStateWithLifecycle()
                    val repeatMode by audioVm.repeatMode.collectAsStateWithLifecycle()
                    scoreHandle?.let { handle ->
                        PlaybackCursorOverlay(
                            scoreHandle = handle,
                            cursorFlow = audioVm.currentCursor,
                            pxPerMM = fitPxPerMM,
                            scale = scale,
                            panOffset = Offset.Zero,
                            // Shared with the PiP surface (pipFit = true): only dim on-screen, PiP stays
                            // fully opaque (iOS parity — the PiP cursor is never dimmed).
                            color = if (pipFit) abAccent else abAccent.copy(alpha = ON_SCREEN_CURSOR_ALPHA),
                            modifier = Modifier.fillMaxSize(),
                        )
                        // Loop region highlight only in A–B loop mode (see the vertical surface note).
                        if (repeatMode == RepeatMode.AB_LOOP) {
                            LoopHighlightOverlay(
                                scoreHandle = handle,
                                loopRangeFlow = audioVm.loopRange,
                                pxPerMM = fitPxPerMM,
                                scale = scale,
                                panOffset = Offset.Zero,
                                color = abAccent.copy(alpha = 0.15f),
                                modifier = Modifier.fillMaxSize(),
                            )
                        }
                        AbBoundaryMarkersOverlay(
                            scoreHandle = handle,
                            aMeasure = aPending,
                            bMeasure = bPending,
                            pxPerMM = fitPxPerMM,
                            scale = scale,
                            panOffset = Offset.Zero,
                            color = abAccent,
                            modifier = Modifier.fillMaxSize(),
                        )
                        annotation?.let { an ->
                            // This surface's content Box IS the document, so the dry layer needs no pan
                            // offset (unlike page mode) and no vertical padding (unlike the vertical
                            // surface, which insets its content).
                            //
                            // WIDTH is the clamped axis here: the horizontal layout is one natural-width
                            // row — far past the 65536 px front-buffer limit on a long piece — while its
                            // height is a single system. So the wet window tracks hScroll, and vertical
                            // only matters when the zoomed row is tall enough to scroll.
                            val wetWindowLeftPx = hScroll.value
                            val wetWindowTopPx = if (needsVScroll) vScroll.value else 0
                            val wetWindowWidthPx = viewportSize.width.coerceAtLeast(0)
                            val wetWindowHeightPx =
                                if (needsVScroll) viewportSize.height.coerceAtLeast(0) else contentHeightPx.toInt()
                            AnnotationLayers(
                                resolveDisplayTransforms = remember(handle) {
                                    musicalDisplayTransformsResolver(handle)
                                },
                                annotation = an,
                                pxPerMM = fitPxPerMM,
                                scale = scale,
                                isDrawing = false,
                                dryPanOffset = Offset.Zero,
                                dryModifier = Modifier.fillMaxSize(),
                                wetWorldToScreen = remember(
                                    fitPxPerMM, scale, wetWindowLeftPx, wetWindowTopPx,
                                ) {
                                    android.graphics.Matrix().apply {
                                        setScale(fitPxPerMM * scale, fitPxPerMM * scale)
                                        postTranslate(-wetWindowLeftPx.toFloat(), -wetWindowTopPx.toFloat())
                                    }
                                },
                                wetModifier = Modifier
                                    .size(
                                        width = with(density) { wetWindowWidthPx.toDp() },
                                        height = with(density) { wetWindowHeightPx.toDp() },
                                    )
                                    .offset { IntOffset(wetWindowLeftPx, wetWindowTopPx) },
                            )
                        }
                    }
                }
            }
        }
    }
}
