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
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.viewinterop.AndroidView
import androidx.ink.rendering.android.canvas.CanvasStrokeRenderer
import androidx.ink.rendering.android.view.ViewStrokeRenderer
import androidx.ink.strokes.Stroke
import com.keynumber.folino.reader.DrawingAnchorWire
import com.keynumber.folino.reader.RawInkStrokeWireCodec
import com.keynumber.folino.reader.ReaderAnnotationJNI
import com.keynumber.folino.reader.StrokeTransformWireCodec
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
    /**
     * Batched anchor→display-transform resolution for a whole layer, positionally aligned with its input
     * — the seam Task 11 (PDF page anchors) generalized this composable's original hardwired `scoreHandle:
     * Long` / `SheetMusicJNI.nativeAnchorReferencePoint` call into: a musical caller (`ReadyScore`/
     * `PagedScore`) closes over its `scoreHandle` and does the ssm ref-point round trip before
     * `ReaderAnnotationJNI.displayTransforms`; a PDF caller (`PdfVerticalScore`/`PagedPdfScore`) closes
     * over its current page frames and calls `ReaderAnnotationJNI.pdfDisplayTransforms` directly — no ssm
     * round trip needed for a page anchor. Returns raw `[StrokeTransformWire]` wire bytes (empty ⇒ the
     * whole batch failed to resolve, e.g. an invalid/stale handle). Callers `remember` this lambda keyed
     * on whatever makes its OWN native call cheap to skip on a live pinch frame (`scoreHandle` for
     * musical, the raster page-frame geometry for PDF) — see this composable's `LaunchedEffect` below,
     * which keys on the lambda's own identity rather than on `scale`/`pxPerMM` directly.
     */
    resolveDisplayTransforms: (List<DrawingAnchorWire>) -> ByteArray,
    drawings: List<DrawingAnchorWire>,
    layoutGeneration: Int,
    pxPerMM: Float,
    scale: Float,
    isDrawing: Boolean,
    modifier: Modifier = Modifier,
    /**
     * Where document (0,0) sits in this overlay View's own coordinate space, matching the sibling
     * cursor / loop overlays' `panOffset`. Zero for the vertical and horizontal surfaces, whose
     * overlay View is the document-sized content Box itself (the vertical surface instead gets its
     * top inset from the `padding(vertical = vPad)` on [modifier], so document y=0 already lands at
     * the View's y=0). Page mode passes `(pan.x, pan.y - pageTop)`: its overlay View is the
     * viewport-sized page Box, so the absolute document coordinates the placements are computed in
     * have to be shifted up by the page band's top edge to land page-locally.
     */
    panOffset: Offset = Offset.Zero,
    onRendered: (List<DrawingAnchorWire>) -> Unit = {},
) {
    // The drawings snapshot and the placement computed from it, kept together: a recomposition triggered by
    // `drawings` changing runs BEFORE the (off-main) recompute finishes, so the snapshot must travel with
    // the placement it produced — reporting `drawings` on its own would tell the caller a stroke is painted
    // a frame or two before it actually is.
    var content by remember { mutableStateOf(DryContent(emptyList(), emptyList())) }
    // `resolveDisplayTransforms` is a key (not `scoreHandle`, now that it's caller-injected) because a
    // caller that rebuilds it on a material change (a reflow, a reparse, a raster-scale settle) needs
    // this effect to re-run; a caller that keeps it `remember`-stable across an unrelated recomposition
    // (a live pinch frame) must NOT retrigger the native round trip on every one of those. `layoutGeneration`
    // is additionally a key because a reflow moves every note under the SAME musical resolver and leaves
    // `drawings` untouched: the anchor reference points these placements were derived from are stale, but
    // nothing else here would tell us. Without it committed ink stays put through a reflow and only snaps
    // into place the next time a stroke is committed.
    LaunchedEffect(resolveDisplayTransforms, drawings, layoutGeneration, isDrawing) {
        if (isDrawing) return@LaunchedEffect
        val placed = withContext(Dispatchers.Default) { computePlacement(resolveDisplayTransforms, drawings) }
        content = DryContent(drawings, placed)
    }

    // `camera` maps document mm → this View's pixels: scale first, then shift by where document (0,0)
    // sits in the View (postTranslate, so the translation is NOT scaled — it is already in px).
    val camera = remember(pxPerMM, scale, panOffset) {
        Matrix().apply {
            setScale(pxPerMM * scale, pxPerMM * scale)
            postTranslate(panOffset.x, panOffset.y)
        }
    }
    val currentOnRendered by rememberUpdatedState(onRendered)

    AndroidView(
        modifier = modifier,
        factory = { ctx -> InkDryView(ctx) },
        update = { view -> view.setContent(content, camera) { currentOnRendered(it) } },
    )
}

/** A committed-drawings snapshot paired with the placement [computePlacement] derived from it. */
private class DryContent(val source: List<DrawingAnchorWire>, val placed: List<Pair<Stroke, Matrix>>)

/**
 * Hardware-accelerated overlay that paints committed androidx.ink [Stroke]s. Transparent background (no
 * background set), so the score + cursor overlays mounted below show through. Each stroke is placed by
 * concatenating its `camera ∘ placement` matrix onto the canvas before [ViewStrokeRenderer]'s
 * `drawStroke`.
 */
private class InkDryView(context: Context) : View(context) {
    private val renderer = CanvasStrokeRenderer.create()
    private val viewRenderer = ViewStrokeRenderer(renderer, this)
    private var content = DryContent(emptyList(), emptyList())
    private var camera: Matrix = Matrix()
    private var reported: DryContent? = null
    private var onRendered: (List<DrawingAnchorWire>) -> Unit = {}

    init {
        // A plain View with an overridden onDraw still needs WILL_NOT_DRAW cleared to be invalidated/redrawn.
        setWillNotDraw(false)
    }

    fun setContent(content: DryContent, camera: Matrix, onRendered: (List<DrawingAnchorWire>) -> Unit) {
        this.content = content
        this.camera = camera
        this.onRendered = onRendered
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val content = this.content
        if (content.placed.isNotEmpty()) {
            viewRenderer.drawWithStrokes(canvas) { scope ->
                content.placed.forEach { (stroke, placement) ->
                    val m = Matrix(camera).apply { preConcat(placement) }
                    val save = canvas.save()
                    canvas.concat(m)
                    scope.drawStroke(stroke)
                    canvas.restoreToCount(save)
                }
            }
        }
        // Report which drawings this frame covers so the wet layer can retire its retained copies (see
        // AnnotationHandoffQueue). Reported even when nothing was placed — a drawing the engine couldn't
        // resolve is still "as painted as it will get", and stranding its wet copy would be worse. Posted
        // rather than called inline: the callback writes state that must not be touched during the draw pass.
        if (reported !== content) {
            reported = content
            post { onRendered(content.source) }
        }
    }
}

/**
 * Resolve display transforms via the caller-injected [resolveDisplayTransforms] (musical ssm round trip,
 * or a PDF page-frame lookup — see that parameter's doc), then rebuild + place each stroke. Off-main.
 */
private fun computePlacement(
    resolveDisplayTransforms: (List<DrawingAnchorWire>) -> ByteArray,
    drawings: List<DrawingAnchorWire>,
): List<Pair<Stroke, Matrix>> {
    if (drawings.isEmpty()) return emptyList()

    val transformsBytes = resolveDisplayTransforms(drawings)
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
