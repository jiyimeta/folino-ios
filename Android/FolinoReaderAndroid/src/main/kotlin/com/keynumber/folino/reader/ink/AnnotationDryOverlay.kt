package com.keynumber.folino.reader.ink

import android.graphics.Matrix
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.ink.rendering.android.canvas.CanvasStrokeRenderer
import androidx.ink.strokes.Stroke
import com.keynumber.folino.reader.DrawingAnchorWire
import com.keynumber.folino.reader.DrawingAnchorWireCodec
import com.keynumber.folino.reader.RawInkStrokeWireCodec
import com.keynumber.folino.reader.ReaderAnnotationJNI
import com.keynumber.folino.reader.ResolvedAnchorWire
import com.keynumber.folino.reader.ResolvedAnchorWireCodec
import com.keynumber.folino.reader.StrokeTransformWireCodec
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.wirelet.observable.WireletList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * DRY render overlay: a Compose `Canvas` sibling of `PlaybackCursorOverlay` (mounted with the same
 * `Modifier.fillMaxSize().padding(vertical = vPadPx.toDp())`, so the local origin already accounts
 * for vPad and `camera` is pure scale). Each reflow, batches the layer's anchors through the ssm +
 * Folino JNI (off the main thread) to get per-stroke placement, rebuilds each androidx.ink [Stroke]
 * from its FINK bytes, and draws with [CanvasStrokeRenderer] at `camera ∘ placement`. Skips the
 * recompute while [isDrawing] so the wet overlay above isn't fighting a reflow mid-stroke.
 */
@Composable
fun AnnotationDryOverlay(
    scoreHandle: Long,
    drawings: List<DrawingAnchorWire>,
    pxPerMM: Float,
    scale: Float,
    isDrawing: Boolean,
    modifier: Modifier = Modifier,
) {
    val renderer = remember { CanvasStrokeRenderer.create() }

    // Placed = (rebuilt Stroke, placement matrix in doc-mm). Recomputed off-main on reflow; NOT while drawing.
    var placed by remember { mutableStateOf<List<Pair<Stroke, Matrix>>>(emptyList()) }
    LaunchedEffect(scoreHandle, drawings, isDrawing) {
        if (isDrawing) return@LaunchedEffect
        placed = withContext(Dispatchers.Default) { computePlacement(scoreHandle, drawings) }
    }

    val camera = remember(pxPerMM, scale) { Matrix().apply { setScale(pxPerMM * scale, pxPerMM * scale) } }

    Canvas(modifier) {
        drawIntoCanvas { c ->
            val native = c.nativeCanvas
            placed.forEach { (stroke, placement) ->
                val m = Matrix(camera).apply { preConcat(placement) }
                renderer.draw(native, stroke, m)
            }
        }
    }
}

/** Batch anchor-ref + display-transform for the whole layer; rebuild + place each stroke. Off-main. */
private fun computePlacement(scoreHandle: Long, drawings: List<DrawingAnchorWire>): List<Pair<Stroke, Matrix>> {
    if (drawings.isEmpty()) return emptyList()

    // ssm ref points for every drawing's anchor identity (send ResolvedAnchorWire; ssm decodes
    // AnchorIdentityWire, skips tags 5-6 — see AnnotationCaptureController for the full rationale).
    val identities = drawings.map {
        ResolvedAnchorWire(it.measureIndex, it.tickInMeasure, it.partIndex, it.staffIndexInPart, it.dxSp, it.verticalOffsetSp)
    }
    val refBytes = SheetMusicJNI.nativeAnchorReferencePoint(
        scoreHandle,
        WireletList.encode(identities, ResolvedAnchorWireCodec::encodePayload),
    )
    if (refBytes.isEmpty()) return emptyList()

    val transformsBytes = ReaderAnnotationJNI.displayTransforms(
        WireletList.encode(drawings, DrawingAnchorWireCodec::encodePayload),
        refBytes,
    )
    if (transformsBytes.isEmpty()) return emptyList()
    val transforms = WireletList.decode(transformsBytes, StrokeTransformWireCodec::decodePayload)

    val out = ArrayList<Pair<Stroke, Matrix>>(drawings.size)
    for (i in drawings.indices) {
        val t = transforms.getOrNull(i) ?: continue
        if (t.sp == 0.0) continue // unresolved this frame — skip (kept in the layer)
        val rawBytes = ReaderAnnotationJNI.decodeInkStroke(drawings[i].encodedDrawing)
        if (rawBytes.isEmpty()) continue
        val rw = RawInkStrokeWireCodec.decode(rawBytes)
        val brush = InkBrushMapping.brushFor(rw.tool.toInt(), rw.colorRGBA.toLong(), rw.baseWidthSp.toFloat())
        val stroke = InkStrokeSerialization.toStroke(rawBytes, brush)
        val placement = Matrix().apply {
            setScale(t.sp.toFloat(), t.sp.toFloat())
            postTranslate(t.px.toFloat(), t.py.toFloat())
        }
        out += stroke to placement
    }
    return out
}
