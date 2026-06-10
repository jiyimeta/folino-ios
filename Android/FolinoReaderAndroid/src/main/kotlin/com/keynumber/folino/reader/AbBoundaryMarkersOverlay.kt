package com.keynumber.folino.reader

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.withTransform
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.DecodedFrame
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.serialization.DecodedFrameCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec

// Marker dimensions in document millimetres (≈ iOS LoopBoundaryMarkers' sp-relative factors).
private const val LINE_THICKNESS_MM = 0.9
private const val TRIANGLE_HEIGHT_MM = 1.8
private const val TRIANGLE_WIDTH_MM = 2.2

/**
 * Accent-colored vertical line + filled triangle flag at each staged A–B loop endpoint, mirroring
 * iOS `LoopBoundaryMarkers`. Each endpoint draws independently, so a single marker appears as soon
 * as A *or* B is set — before the other is chosen (i.e. before the loop region exists). Sits in the
 * same Box as `ScorePage` / `PlaybackCursorOverlay` / `LoopHighlightOverlay` and uses identical
 * transform params so the bars align with the score columns.
 *
 * A's bar sits at the LEFT edge of its measure with the flag pointing right; B's bar sits at the
 * RIGHT edge with the flag pointing left.
 *
 * @param aMeasure staged A measure index (or null).
 * @param bMeasure staged B measure index (or null).
 */
@Composable
fun AbBoundaryMarkersOverlay(
    scoreHandle: Long,
    aMeasure: Int?,
    bMeasure: Int?,
    pxPerMM: Float,
    scale: Float,
    panOffset: Offset,
    color: Color,
    modifier: Modifier = Modifier,
) {
    var aFrame by remember { mutableStateOf<DecodedFrame?>(null) }
    var bFrame by remember { mutableStateOf<DecodedFrame?>(null) }

    LaunchedEffect(scoreHandle, aMeasure) { aFrame = aMeasure?.let { measureFrame(scoreHandle, it) } }
    LaunchedEffect(scoreHandle, bMeasure) { bFrame = bMeasure?.let { measureFrame(scoreHandle, it) } }

    if (aFrame == null && bFrame == null) return

    Canvas(modifier = modifier) {
        withTransform({
            translate(panOffset.x, panOffset.y)
            scale(scale, scale, pivot = Offset.Zero)
        }) {
            aFrame?.let { drawEndpointMarker(it, atStart = true, pxPerMM = pxPerMM, color = color) }
            bFrame?.let { drawEndpointMarker(it, atStart = false, pxPerMM = pxPerMM, color = color) }
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

/** Draws one endpoint: a vertical line at the measure's leading (A) / trailing (B) edge + a flag. */
private fun DrawScope.drawEndpointMarker(
    frame: DecodedFrame,
    atStart: Boolean,
    pxPerMM: Float,
    color: Color,
) {
    val lineXmm = if (atStart) frame.x else frame.x + frame.width
    val topMm = frame.y - TRIANGLE_HEIGHT_MM
    val bottomMm = frame.y + frame.height
    val lineX = lineXmm.toFloat() * pxPerMM
    val thickness = LINE_THICKNESS_MM.toFloat() * pxPerMM

    drawRect(
        color = color,
        topLeft = Offset(lineX - thickness / 2f, topMm.toFloat() * pxPerMM),
        size = Size(thickness, (bottomMm - topMm).toFloat() * pxPerMM),
    )

    val triH = TRIANGLE_HEIGHT_MM.toFloat() * pxPerMM
    val triW = TRIANGLE_WIDTH_MM.toFloat() * pxPerMM
    val baseY = frame.y.toFloat() * pxPerMM // flag base sits at the system top
    val apexX = if (atStart) lineX + triW else lineX - triW
    val flag = Path().apply {
        moveTo(lineX, baseY - triH)
        lineTo(apexX, baseY - triH / 2f)
        lineTo(lineX, baseY)
        close()
    }
    drawPath(flag, color = color)
}
