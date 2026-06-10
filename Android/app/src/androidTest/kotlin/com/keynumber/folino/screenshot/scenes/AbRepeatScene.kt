package com.keynumber.folino.screenshot.scenes

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import io.github.jiyimeta.sheetmusic.audio.model.DecodedFrame
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.serialization.DecodedFrameCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec
import io.github.jiyimeta.sheetmusic.compose.render.ScorePage
import io.github.jiyimeta.sheetmusic.compose.render.bundledFontProvider

// AB-section repeat scene: the score scrolled so a mid-piece line is at the top, with accent-colored A
// and B boundary markers (the same `AbBoundaryMarkersOverlay` the production Reader uses) bracketing that
// line's two measures. Engine-independent: the markers are resolved purely from the laid-out score via
// JNI (`nativeMeasureFrame`), so no audio engine / loop controller is needed for the still.
//
// `AbBoundaryMarkersOverlay` takes 0-indexed measure indices. This score (Now_is_the_time) lays out two
// measures per system after the intro: indices {1,2}, {3}, {4,5}, {6,7}, {8,9} each share a line. To keep
// the looped region on ONE line (so the A and B flags clearly bracket a contiguous span rather than
// straddling a system break), we frame the {4,5} system — measures 5 & 6 as a user counts them 1-indexed
// (index 0 is the intro/pickup measure). A sits at the leading edge of index 4, B at the trailing edge of
// index 5, bracketing that full two-measure line.
private const val A_MEASURE_INDEX = 4
private const val B_MEASURE_INDEX = 5

// Leave a little breathing room (document mm) above the looped system once scrolled into view.
private const val TOP_AIR_MM = 14.0

@Composable
fun AbRepeatScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("AbRepeat", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout) {
        FolinoTheme {
            // VERTICAL (continuous) layout: the whole score lays out as ONE tall page in a single
            // coordinate space, so `nativeMeasureFrame` y-values align with `ScorePage` — the space
            // `AbBoundaryMarkersOverlay` and the auto-scroll math were designed for. (PAGE mode, the
            // DEFAULT, paginates so `pages.first()` would only hold measure 1.)
            val scene = rememberReaderSceneState {
                LayoutOptions.DEFAULT.copy(mode = ReaderLayoutMode.VERTICAL)
            }
            Box(Modifier.fillMaxSize().background(Color.White).clipToBounds()) {
                if (scene != null) {
                    AbScoreWithMarkers(state = scene.state, scoreHandle = scene.scoreHandle)
                }
            }
        }
    }
}

// Scene-local adaptation of `ReaderSceneContent` that ALSO draws the A–B boundary markers in the same
// transformed Box as the page (so the bars align with the score columns) and scrolls vertically to frame
// the looped line. The scroll amount is DERIVED from the A measure's resolved frame (via
// `nativeMeasureFrame`) rather than tuned by hand: we shift the content up by (A.y − air) document-mm.
// Readiness is gated on the A frame resolving, so the capture never fires before the markers can paint.
@Composable
private fun AbScoreWithMarkers(state: ReaderState.Ready, scoreHandle: Long) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val fontProvider = remember(context) { bundledFontProvider(context) }
    val accent = androidx.compose.material3.MaterialTheme.colorScheme.primary

    val page = state.program.pages.first()
    var viewportSize by remember { mutableStateOf(IntSize.Zero) }

    val fitPxPerMM = if (page.widthMM > 0 && viewportSize.width > 0) {
        (viewportSize.width / page.widthMM).toFloat()
    } else {
        0f
    }
    val vPadPx = with(density) { 16.dp.toPx() }

    // Resolve the A measure's frame (mm) once the score is laid out, derive the scroll-up from its y.
    var aFrame by remember { mutableStateOf<DecodedFrame?>(null) }
    LaunchedEffect(scoreHandle) {
        aFrame = measureFrame(scoreHandle, A_MEASURE_INDEX)
    }
    // mm above the page origin to drop so the looped line sits near the top with a little air.
    val scrollUpMM = ((aFrame?.y ?: 0.0) - TOP_AIR_MM).coerceAtLeast(0.0)
    val scrollUp: Dp = with(density) { (scrollUpMM.toFloat() * fitPxPerMM).toDp() }

    LaunchedEffect(scoreHandle, fitPxPerMM, viewportSize, aFrame) {
        if (fitPxPerMM <= 0f || viewportSize.width <= 0 || aFrame == null) return@LaunchedEffect
        // Markers + scroll are settled. Let a few frames paint, then release the capture gate.
        kotlinx.coroutines.delay(500)
        SceneReady.signalReady()
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.White)
            .clipToBounds()
            .onSizeChanged { viewportSize = it },
        contentAlignment = Alignment.TopStart,
    ) {
        val contentWidthPx = page.widthMM.toFloat() * fitPxPerMM
        val contentHeightPx = page.heightMM.toFloat() * fitPxPerMM
        Box(
            Modifier
                .size(
                    width = with(density) { contentWidthPx.toDp() },
                    height = with(density) { (contentHeightPx + vPadPx * 2).toDp() },
                )
                // Shift the whole stack up so the looped line lands near the top of the viewport.
                .offset(y = -scrollUp),
        ) {
            ScorePage(
                page = page,
                fontProvider = fontProvider,
                pxPerMM = fitPxPerMM,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = with(density) { vPadPx.toDp() }),
            )
            // Markers live in the SAME padded Box as ScorePage and share its `.padding(vertical)`, so the
            // bars share the page's coordinate origin (document mm scaled by pxPerMM); panOffset stays
            // zero, mirroring how ReaderSceneContent positions PlaybackCursorOverlay.
            AbBoundaryMarkersOverlay(
                scoreHandle = scoreHandle,
                aMeasure = A_MEASURE_INDEX,
                bMeasure = B_MEASURE_INDEX,
                pxPerMM = fitPxPerMM,
                scale = 1f,
                panOffset = Offset.Zero,
                color = accent,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(vertical = with(density) { vPadPx.toDp() }),
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
