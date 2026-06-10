package com.keynumber.folino.screenshot.scenes

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
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
import com.keynumber.folino.reader.ReaderLayoutMode
import com.keynumber.folino.reader.ReaderState
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.SceneReady
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

// AB-section repeat scene: the score in the Reader's HORIZONTAL (single continuous-row) layout, scrolled
// horizontally so measures 5–7 sit side-by-side in one strip, with a translucent accent BAND filling the
// looped measures (the production `LoopHighlightOverlay`) and bold accent A/B boundary flags
// (`AbBoundaryMarkersOverlay`) bracketing the span. Horizontal beats VERTICAL here because this score has
// six staves per system — three vertically-stacked measures never fit one phone frame, whereas one
// natural-width row lets all three looped measures + both flags read at once as a single highlighted run.
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

// Horizontal air (document mm) on EACH side of the m5–7 span, so the A/B flags aren't flush against the
// frame edges. The looped span + this air on both sides is scaled to exactly fill the viewport width, so
// all three measures and both flags are always in frame regardless of the score's natural measure widths.
private const val SIDE_AIR_MM = 12.0

// Translucent accent band over the looped measures. Matches the production HorizontalScore band tint.
private fun loopBand(accent: Color): Color = accent.copy(alpha = 0.18f)

@Composable
fun AbRepeatScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("AbRepeat", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout) {
        FolinoTheme {
            // HORIZONTAL (single natural-width row) layout: the whole score lays out as ONE wide page in a
            // single coordinate space, so `nativeMeasureFrame` / `nativeLoopHighlightRects` x/y align with
            // `ScorePage`. We scroll horizontally (offset x) to bring m5–7 into the frame.
            val scene = rememberReaderSceneState {
                LayoutOptions.DEFAULT.copy(mode = ReaderLayoutMode.HORIZONTAL)
            }
            Box(Modifier.fillMaxSize().background(Color.White).clipToBounds()) {
                if (scene != null) {
                    AbScoreWithMarkers(state = scene.state, scoreHandle = scene.scoreHandle)
                }
            }
        }
    }
}

// Scene-local horizontal adaptation: renders the natural-width row, scrolls horizontally so m5's leading
// edge parks near the left (derived from the A measure's resolved frame, not hand-tuned), centers the row
// vertically, and draws the loop band + A/B markers in the SAME transformed Box as the page so they align
// with the score columns. Readiness is gated on the A frame AND the loop range resolving.
@Composable
private fun AbScoreWithMarkers(state: ReaderState.Ready, scoreHandle: Long) {
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

    // Fit the m5→m7 span (+ side air on both sides) to the viewport width, so the looped run dominates and
    // both flags stay in frame independent of the score's natural measure widths.
    val a = aFrame
    val b = bFrame
    val spanLeftMM = (a?.x ?: 0.0) - SIDE_AIR_MM
    val spanRightMM = ((b?.x ?: 0.0) + (b?.width ?: 0.0)) + SIDE_AIR_MM
    val spanWidthMM = (spanRightMM - spanLeftMM).coerceAtLeast(1.0)
    val fitPxPerMM = if (a != null && b != null && viewportSize.width > 0) {
        (viewportSize.width / spanWidthMM).toFloat()
    } else {
        0f
    }

    // mm left of the page origin to drop so the span's left edge (m5 − air) parks at the viewport's left.
    val scrollLeftMM = spanLeftMM.coerceAtLeast(0.0)
    val scrollLeft: Dp = with(density) { (scrollLeftMM.toFloat() * fitPxPerMM).toDp() }

    LaunchedEffect(scoreHandle, fitPxPerMM, viewportSize, aFrame, bFrame, loopRange) {
        if (fitPxPerMM <= 0f || viewportSize.width <= 0 || a == null || b == null || loopRange == null) {
            return@LaunchedEffect
        }
        // Band + markers + scroll are settled. Let a few frames paint, then release the capture gate.
        kotlinx.coroutines.delay(500)
        SceneReady.signalReady()
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.White)
            .clipToBounds()
            .onSizeChanged { viewportSize = it },
        // Center the single row vertically (HorizontalScore centers a short row in the viewport).
        contentAlignment = Alignment.CenterStart,
    ) {
        val contentWidthPx = page.widthMM.toFloat() * fitPxPerMM
        val contentHeightPx = page.heightMM.toFloat() * fitPxPerMM
        Box(
            Modifier
                .size(
                    width = with(density) { contentWidthPx.toDp() },
                    height = with(density) { contentHeightPx.toDp() },
                )
                // Shift the whole row left so m5 lands near the left edge of the viewport.
                .offset(x = -scrollLeft),
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
