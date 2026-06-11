package com.keynumber.folino.screenshot.scenes

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.keynumber.folino.reader.AbBoundaryMarkersOverlay
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.reader.PlaybackFab
import com.keynumber.folino.reader.ReaderAudioViewModel
import com.keynumber.folino.reader.ReaderLayoutMode
import com.keynumber.folino.reader.ReaderState
import com.keynumber.folino.reader.ReaderTopBar
import com.keynumber.folino.reader.fixedPxPerMm
import com.keynumber.folino.reader.layoutWidthMm
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.READER_SCENE_TITLE
import com.keynumber.folino.screenshot.fixtures.SCREENSHOT_STAFF_SIZE
import com.keynumber.folino.screenshot.fixtures.SceneReady
import com.keynumber.folino.screenshot.fixtures.rememberPreparedAudioVm
import com.keynumber.folino.screenshot.fixtures.rememberReaderSceneState
import com.keynumber.folino.screenshot.frame.ScreenshotFrame
import com.keynumber.folino.screenshot.frame.ScreenshotLayout
import com.keynumber.folino.ui.theme.FolinoTheme
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.DecodedFrame
import io.github.jiyimeta.sheetmusic.audio.model.LoopRange
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.serialization.DecodedFrameCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.FrameCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec
import io.github.jiyimeta.sheetmusic.compose.cursor.LoopHighlightOverlay
import io.github.jiyimeta.sheetmusic.compose.render.ScorePage
import io.github.jiyimeta.sheetmusic.compose.render.bundledFontProvider
import kotlinx.coroutines.flow.MutableStateFlow

// AB-section repeat scene: the score in the Reader's VERTICAL (one continuous stacked page) layout, scrolled
// vertically so measures 5–7 sit in frame, with a translucent accent BAND filling the looped measures (the
// production `LoopHighlightOverlay`) and bold accent A/B boundary flags (`AbBoundaryMarkersOverlay`)
// bracketing the span. This score lays out ~2 measures per system after a 1-measure intro, so m5–7 span ~2
// adjacent stacked systems; we fit the page to the viewport WIDTH and scroll vertically so those systems
// (and their band/flags) land centered in the frame — the band reading across the two systems is expected.
//
// Both overlays are engine-INDEPENDENT: the band's tick range is resolved straight from the laid-out score
// via the audio JNI's measure→tick conversion (the SAME `frameForCursor` + `FrameCodec` path
// `AndroidPlaybackEngine.setLoopMeasures` uses), reached through the public
// `AndroidPlaybackEngine.defaultBridge` seam — so no audio engine / loop controller has to be running.
//
// The overlays take 0-indexed measure indices. Index 0 is the intro/pickup measure, so 1-indexed measure
// N maps to index (N-1): m5=index 4, m6=index 5, m7=index 6. We loop MEASURES 5–7 = indices 4 THROUGH 6
// inclusive — A sits at the leading edge of m5 (index 4), B at the trailing edge of m7 (index 6).
private const val A_MEASURE_INDEX = 4 // m5: loop start (left edge)
private const val B_MEASURE_INDEX = 6 // m7: loop end (right edge)

// Vertical air (document mm) above the A system and below the B system, so the looped systems aren't flush
// against the frame edges when their combined height is scaled to fill the viewport. (In VERTICAL the page
// is already laid out at the viewport's natural width; this only governs the vertical fit of the m5–7 run.)
private const val SIDE_AIR_MM = 8.0

// Translucent accent band over the looped measures. Matches the production HorizontalScore band tint.
private fun loopBand(accent: Color): Color = accent.copy(alpha = 0.18f)

@Composable
fun AbRepeatScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("AbRepeat", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout, subtitleBullet = copy.bullet) {
        FolinoTheme {
            // VERTICAL (one continuous stacked page) layout: the whole score lays out as ONE tall page in a
            // single coordinate space, so `nativeMeasureFrame` / `nativeLoopHighlightRects` x/y align with
            // `ScorePage`. We fit to viewport WIDTH and scroll vertically (offset y) to bring m5–7 into frame.
            val scene = rememberReaderSceneState {
                LayoutOptions.DEFAULT.copy(
                    mode = ReaderLayoutMode.VERTICAL,
                    staffSize = SCREENSHOT_STAFF_SIZE,
                )
            }
            // Live, prepared engine VM so the real PlaybackFab renders enabled (bound engine +
            // populated mixer). Null until the service binds and the score is prepared. This drives
            // the production audio path; the AB band/markers below are engine-INDEPENDENT (they reach
            // the JNI via `AndroidPlaybackEngine.defaultBridge`), so the two don't conflict.
            val audioVm = rememberPreparedAudioVm(scene?.scoreHandle)
            Column(Modifier.fillMaxSize().background(Color.White)) {
                // Real Reader top app bar; static screenshot, callbacks are no-ops.
                ReaderTopBar(
                    title = READER_SCENE_TITLE,
                    onBack = {},
                    onShare = {},
                    onEditInfo = {},
                    onPlaybackControls = {},
                    onDisplaySettings = {},
                    windowInsets = WindowInsets(0, 0, 0, 0),
                )
                Box(Modifier.fillMaxSize().weight(1f).background(Color.White).clipToBounds()) {
                    if (scene != null) {
                        AbScoreWithMarkers(
                            state = scene.state,
                            scoreHandle = scene.scoreHandle,
                            audioVm = audioVm,
                            onLayoutWidthMm = scene.viewModel::setLayoutWidthMm,
                        )
                        if (audioVm != null) {
                            // Engine prepared: render the real seek-bar-OFF transport cluster at the
                            // bottom-end (ReaderScreen's FAB slot) over the score, same as scene 10.
                            Box(
                                Modifier
                                    .align(Alignment.BottomEnd)
                                    .padding(16.dp),
                            ) {
                                PlaybackFab(audioVm)
                            }
                        }
                    }
                }
            }
        }
    }
}

// Scene-local vertical adaptation: renders the continuous page fit-to-width, scrolls vertically so the m5–7
// run (the A system's top through the B system's bottom, derived from the resolved measure frames, not
// hand-tuned) sits centered in the viewport, and draws the loop band + A/B markers in the SAME transformed
// Box as the page so they align with the score systems. Readiness is gated on the frames AND the loop range.
@Composable
private fun AbScoreWithMarkers(
    state: ReaderState.Ready,
    scoreHandle: Long,
    audioVm: ReaderAudioViewModel?,
    onLayoutWidthMm: (Double) -> Unit = {},
) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val fontProvider = remember(context) { bundledFontProvider(context) }
    val accent = androidx.compose.material3.MaterialTheme.colorScheme.primary

    val page = state.program.pages.first()
    var viewportSize by remember { mutableStateOf(IntSize.Zero) }

    // Resolve the A (m5) and B (m7) measure frames (mm) once laid out. Their x-span (plus side air) is what
    // we fit to the viewport width — so all three looped measures + both flags always land in frame.
    var aFrame by remember { mutableStateOf<DecodedFrame?>(null) }
    var bFrame by remember { mutableStateOf<DecodedFrame?>(null) }
    LaunchedEffect(scoreHandle) {
        aFrame = measureFrame(scoreHandle, A_MEASURE_INDEX)
        bFrame = measureFrame(scoreHandle, B_MEASURE_INDEX)
    }

    // Resolve the loop tick range for measures 5–7 (indices A..B inclusive) the SAME way
    // `AndroidPlaybackEngine.setLoopMeasures` does: start = onset tick of index A; end = onset tick of the
    // measure AFTER B (index B+1), or the timeline's total ticks when that beat doesn't resolve. Drives a
    // MutableStateFlow into the production `LoopHighlightOverlay` so the three measures get an accent band.
    val loopFlow = remember { MutableStateFlow<LoopRange?>(null) }
    LaunchedEffect(scoreHandle) {
        loopFlow.value = resolveLoopRange(scoreHandle, A_MEASURE_INDEX, B_MEASURE_INDEX)
    }
    val loopRange by loopFlow.collectAsStateValue()

    // VERTICAL: fit the continuous page to the viewport WIDTH (the natural Reader vertical-scroll fit), then
    // scroll vertically so the m5–7 run lands centered. In VERTICAL the A (m5) and B (m7) systems are stacked,
    // so the looped run's vertical extent is A's top through B's bottom; X spans the full page width.
    val a = aFrame
    val b = bFrame
    // Fixed-density render (same pxPerMM on phone and tablet); the band/scroll formulae below work at any
    // fitPxPerMM. Report the viewport-derived layout width to the VM so the page reflows like production.
    val fitPxPerMM = if (a != null && b != null && viewportSize.width > 0) {
        fixedPxPerMm(density.density)
    } else {
        0f
    }
    LaunchedEffect(viewportSize.width, density.density) {
        if (viewportSize.width > 0) onLayoutWidthMm(layoutWidthMm(viewportSize.width, density.density))
    }

    // No horizontal scroll: the page is fit to width, so the row of every system already fills the frame.
    val scrollLeft: Dp = 0.dp

    // Vertically center the looped RUN (A system top − air … B system bottom + air) in the viewport. Each
    // `nativeMeasureFrame` returns that measure's full system column, so a.y is the top of m5's system and
    // b.y+b.height is the bottom of m7's system; park the run's midpoint at the viewport's vertical center.
    val runTopMM = (a?.y ?: 0.0) - SIDE_AIR_MM
    val runBottomMM = ((b?.y ?: 0.0) + (b?.height ?: 0.0)) + SIDE_AIR_MM
    val runMidMM = (runTopMM + runBottomMM) / 2.0
    val scrollTop: Dp = with(density) {
        ((runMidMM.toFloat() * fitPxPerMM) - viewportSize.height / 2f).toDp()
    }

    LaunchedEffect(scoreHandle, fitPxPerMM, viewportSize, aFrame, bFrame, loopRange, audioVm) {
        if (fitPxPerMM <= 0f || viewportSize.width <= 0 || a == null || b == null || loopRange == null) {
            return@LaunchedEffect
        }
        // Also wait on the prepared engine so the real PlaybackFab cluster renders enabled before capture.
        if (audioVm == null) return@LaunchedEffect
        // Band + markers + scroll + transport are settled. Let a few frames paint, then release the gate.
        kotlinx.coroutines.delay(500)
        SceneReady.signalReady()
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.White)
            .clipToBounds()
            .onSizeChanged { viewportSize = it },
        // Top-anchor: the looped system is centered via an explicit y-offset (below), not box alignment,
        // so it stays centered even when the (smaller-staff) page is shorter than the viewport.
        contentAlignment = Alignment.TopStart,
    ) {
        val contentWidthPx = page.widthMM.toFloat() * fitPxPerMM
        val contentHeightPx = page.heightMM.toFloat() * fitPxPerMM
        Box(
            Modifier
                .size(
                    width = with(density) { contentWidthPx.toDp() },
                    height = with(density) { contentHeightPx.toDp() },
                )
                // Shift left so m5 lands near the left edge; shift up so the looped system centers.
                .offset(x = -scrollLeft, y = -scrollTop),
        ) {
            ScorePage(
                page = page,
                fontProvider = fontProvider,
                pxPerMM = fitPxPerMM,
                modifier = Modifier.fillMaxSize(),
            )
            // Band UNDER the markers, in the SAME Box as ScorePage so it shares the page coordinate origin
            // (document mm scaled by pxPerMM); panOffset zero, scale 1 — mirroring HorizontalScore.
            LoopHighlightOverlay(
                scoreHandle = scoreHandle,
                loopRangeFlow = loopFlow,
                pxPerMM = fitPxPerMM,
                scale = 1f,
                panOffset = Offset.Zero,
                color = loopBand(accent),
                modifier = Modifier.fillMaxSize(),
            )
            // A/B flags on top of the band, full-opacity accent so they bracket the band boldly.
            AbBoundaryMarkersOverlay(
                scoreHandle = scoreHandle,
                aMeasure = A_MEASURE_INDEX,
                bMeasure = B_MEASURE_INDEX,
                pxPerMM = fitPxPerMM,
                scale = 1f,
                panOffset = Offset.Zero,
                color = accent,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

/** Resolves a measure's bounding rect (mm) via the shared JNI; null when the measure doesn't resolve. */
private fun measureFrame(scoreHandle: Long, measureIndex: Int): DecodedFrame? {
    val bytes = SheetMusicJNI.nativeMeasureFrame(
        scoreHandle,
        ScoreCursorCodec.encode(ScoreCursor.Beat(measureIndex, 0)),
    )
    return if (bytes.isEmpty()) null else DecodedFrameCodec.decode(bytes)
}

/**
 * Tick onset of [measureIndex] (beat 0), via the audio JNI's measure→tick conversion reached through the
 * public [AndroidPlaybackEngine.defaultBridge] — the exact path `setLoopMeasures` uses. Null when the beat
 * doesn't resolve (e.g. an index past the last measure).
 */
private fun measureOnsetTick(scoreHandle: Long, measureIndex: Int): Long? {
    val bytes = AndroidPlaybackEngine.defaultBridge.frameForCursor(
        scoreHandle,
        ScoreCursorCodec.encode(ScoreCursor.Beat(measureIndex, 0)),
    )
    return if (bytes.isEmpty()) null else FrameCodec.decode(bytes).tick
}

/**
 * Half-open loop range `[startTick, endTick)` covering measures `[fromIndex, toIndex]` inclusive, matching
 * `AndroidPlaybackEngine.setLoopMeasures`: start = onset of [fromIndex]; end = onset of [toIndex]+1, or the
 * timeline's total ticks (`timelineSummary[0]`) when that beat is past the score end. Null on no resolve.
 */
private fun resolveLoopRange(scoreHandle: Long, fromIndex: Int, toIndex: Int): LoopRange? {
    val start = measureOnsetTick(scoreHandle, fromIndex) ?: return null
    val totalTicks = AndroidPlaybackEngine.defaultBridge.timelineSummary(scoreHandle).firstOrNull() ?: 0L
    val end = measureOnsetTick(scoreHandle, toIndex + 1) ?: totalTicks
    return if (start >= end) null else LoopRange(startTick = start, endTick = end)
}

// Tiny local collector so the StateFlow's current value drives recomposition without pulling in the
// runtime-compose `collectAsState` import set here.
@Composable
private fun <T> MutableStateFlow<T>.collectAsStateValue(): State<T> {
    val state = remember { mutableStateOf(value) }
    LaunchedEffect(this) { collect { state.value = it } }
    return state
}
