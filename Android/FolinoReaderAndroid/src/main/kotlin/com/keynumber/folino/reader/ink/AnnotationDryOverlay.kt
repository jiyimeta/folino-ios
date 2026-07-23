package com.keynumber.folino.reader.ink

import android.content.Context
import android.graphics.Canvas
import android.graphics.Matrix
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.ink.rendering.android.canvas.CanvasStrokeRenderer
import androidx.ink.rendering.android.view.ViewStrokeRenderer
import androidx.ink.strokes.Stroke
import com.keynumber.folino.reader.DrawingAnchorWire
import com.keynumber.folino.reader.DrawingAnchorWireCodec
import com.keynumber.folino.reader.RawInkStrokeWireCodec
import com.keynumber.folino.reader.ReaderAnnotationJNI
import com.keynumber.folino.reader.ResolvedAnchorWire
import com.keynumber.folino.reader.ResolvedAnchorWireCodec
import com.keynumber.folino.reader.StrokeTransformWireCodec
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * DRY render overlay for committed strokes: an `AndroidView`-wrapped [InkDryView], sibling of the
 * cursor/loop overlays inside the sized content `Box` (mounted with the same
 * `Modifier.fillMaxSize().padding(vertical = vPadPx.toDp())`, so the View origin already accounts for
 * vPad and `camera` is pure scale). Each reflow, batches the layer's anchors through the ssm + Folino
 * JNI (off the main thread) to get per-stroke placement, rebuilds each androidx.ink [Stroke] from its
 * FINK bytes, and hands (stroke, placement) pairs to the View, which draws them in its hardware-
 * accelerated `onDraw`. Skips the recompute while [isDrawing] so the wet overlay above isn't fighting a
 * reflow mid-stroke.
 *
 * Why a real [View] and not a Compose `Canvas`: androidx.ink renders a [Stroke] with
 * [CanvasStrokeRenderer]/[ViewStrokeRenderer] where the stroke is PLACED BY THE CANVAS'S CURRENT
 * TRANSFORM (the `Matrix` argument to `CanvasStrokeRenderer.draw` is only the stroke->screen LOD hint,
 * not the placement — see `ViewStrokeRenderer.StrokeDrawScope.drawStroke(stroke)`, which takes no
 * matrix at all and reads the canvas matrix). Drawing into a Compose `drawIntoCanvas` canvas without
 * concatenating the placement (and with no guaranteed hardware-accelerated `Canvas.drawMesh`) rendered
 * nothing visible. A `View.onDraw` gives a hardware canvas, and [ViewStrokeRenderer] supplies the
 * view->screen transform for correct mesh level-of-detail.
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
    // Placed = (rebuilt Stroke, placement matrix in doc-mm). Recomputed off-main on reflow; NOT while drawing.
    var placed by remember { mutableStateOf<List<Pair<Stroke, Matrix>>>(emptyList()) }
    LaunchedEffect(scoreHandle, drawings, isDrawing) {
        if (isDrawing) return@LaunchedEffect
        placed = withContext(Dispatchers.Default) { computePlacement(scoreHandle, drawings) }
    }

    val camera = remember(pxPerMM, scale) { Matrix().apply { setScale(pxPerMM * scale, pxPerMM * scale) } }

    AndroidView(
        modifier = modifier,
        factory = { ctx -> InkDryView(ctx) },
        update = { view -> view.setContent(placed, camera) },
    )
}

/**
 * Hardware-accelerated overlay that paints committed androidx.ink [Stroke]s. Transparent background (no
 * background set), so the score + cursor overlays mounted below show through. Each stroke is placed by
 * concatenating its `camera ∘ placement` matrix onto the canvas before [ViewStrokeRenderer]'s
 * `drawStroke`.
 */
private class InkDryView(context: Context) : View(context) {
    private val renderer = CanvasStrokeRenderer.create()
    private val viewRenderer = ViewStrokeRenderer(renderer, this)
    private var placed: List<Pair<Stroke, Matrix>> = emptyList()
    private var camera: Matrix = Matrix()

    init {
        // A plain View with an overridden onDraw still needs WILL_NOT_DRAW cleared to be invalidated/redrawn.
        setWillNotDraw(false)
    }

    fun setContent(placed: List<Pair<Stroke, Matrix>>, camera: Matrix) {
        this.placed = placed
        this.camera = camera
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        if (placed.isEmpty()) return
        viewRenderer.drawWithStrokes(canvas) { scope ->
            placed.forEach { (stroke, placement) ->
                val m = Matrix(camera).apply { preConcat(placement) }
                val save = canvas.save()
                canvas.concat(m)
                scope.drawStroke(stroke)
                canvas.restoreToCount(save)
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
        encodeWireArray(identities, ResolvedAnchorWireCodec::encodePayload),
    )
    if (refBytes.isEmpty()) return emptyList()

    val transformsBytes = ReaderAnnotationJNI.displayTransforms(
        encodeWireArray(drawings, DrawingAnchorWireCodec::encodePayload),
        refBytes,
    )
    if (transformsBytes.isEmpty()) return emptyList()
    val transforms = decodeWireArray(transformsBytes, StrokeTransformWireCodec::decodePayload)

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
