package com.keynumber.folino.reader.ink

import androidx.compose.ui.geometry.Offset
import com.keynumber.folino.reader.DrawingAnchorWire
import com.keynumber.folino.reader.DrawingAnchorWireCodec
import com.keynumber.folino.reader.EraseRequestWire
import com.keynumber.folino.reader.EraseRequestWireCodec
import com.keynumber.folino.reader.EraseResultWireCodec
import com.keynumber.folino.reader.RawInkStrokeWireCodec
import com.keynumber.folino.reader.ReaderAnnotationJNI
import com.keynumber.folino.reader.ResolvedAnchorWire
import com.keynumber.folino.reader.ResolvedAnchorWireCodec
import com.keynumber.folino.reader.StrokeTransformWireCodec
import io.github.jiyimeta.sheetmusic.SheetMusicJNI

/** Phase-1 (`applyErase`) result: the layer after the cut, plus which indices are fragments that need Phase 2. */
data class EraseOutcome(val drawings: List<DrawingAnchorWire>, val changedIndices: List<Int>)

/**
 * Sequences the two-phase partial eraser. All the geometry (path-vs-stroke cut, anchor placement) lives
 * in shared Swift, reached through [ReaderAnnotationJNI] / [SheetMusicJNI] — this only wires the calls
 * together, mirroring [AnnotationDryOverlay]'s `computePlacement` (Phase 1's anchor-ref + display-
 * transform half) and [AnnotationCaptureController] (Phase 2's per-fragment re-anchor).
 *
 * Why two phases instead of one native call: cutting the layer (Phase 1) is cheap and reflow-independent
 * — it only needs the CURRENT display placement to hit-test the eraser path against. But a cut fragment
 * no longer shares its parent's geometry, so it can't keep sharing the parent's anchor once the score
 * reflows; only re-running the full capture pipeline (Phase 2) on the fragment's OWN geometry gives it an
 * anchor that will track correctly. Splitting the phases lets the cut happen synchronously on the erase
 * gesture while the (heavier, per-fragment) re-anchor can be batched or deferred without blocking ink.
 */
object AnnotationEraseController {
    /**
     * Phase 1: cut the layer along `pathMm` (document-mm polyline, `radiusMm` geometric radius). Fragments
     * inherit the parent drawing's anchor — they render correctly immediately but haven't been re-anchored
     * yet (that's [reanchor]). Returns null when any native step fails to decode; the caller must leave
     * the layer untouched rather than risk applying a partial cut.
     */
    fun applyErase(
        drawings: List<DrawingAnchorWire>,
        scoreHandle: Long,
        pathMm: List<Offset>,
        radiusMm: Float,
    ): EraseOutcome? {
        // Nothing to erase — return null (not an empty outcome) so the caller leaves the layer untouched.
        if (drawings.isEmpty()) return null

        // Encoded once and reused below: this runs ~20x/sec during an erase drag, and re-serializing the
        // whole layer (every FINK payload included) a second time per call is pure waste.
        val encodedDrawings = encodeWireArray(drawings, DrawingAnchorWireCodec::encodePayload)

        // Same anchor-ref + display-transform pair as `computePlacement`: the erase hit-test must run in
        // the display space the user actually saw the ink in, not the anchor-relative storage space.
        val identities = drawings.map {
            ResolvedAnchorWire(it.measureIndex, it.tickInMeasure, it.partIndex, it.staffIndexInPart, it.dxSp, it.verticalOffsetSp)
        }
        val refBytes = SheetMusicJNI.nativeAnchorReferencePoint(
            scoreHandle,
            encodeWireArray(identities, ResolvedAnchorWireCodec::encodePayload),
        )
        if (refBytes.isEmpty()) return null

        val transformsBytes = ReaderAnnotationJNI.displayTransforms(encodedDrawings, refBytes)
        if (transformsBytes.isEmpty()) return null

        val request = EraseRequestWire(
            xMm = pathMm.map { it.x.toDouble() },
            yMm = pathMm.map { it.y.toDouble() },
            radiusMm = radiusMm.toDouble(),
        )
        val resultBytes = ReaderAnnotationJNI.erase(encodedDrawings, transformsBytes, EraseRequestWireCodec.encode(request))
        if (resultBytes.isEmpty()) return null

        val result = EraseResultWireCodec.decode(resultBytes)
        return EraseOutcome(result.drawings, result.changedIndices)
    }

    /**
     * Phase 2: re-anchor the fragments Phase 1 flagged in `changedIndices` (indices into the POST-erase
     * `drawings`, i.e. [EraseOutcome.drawings]) so each gets its own anchor instead of the parent's
     * inherited one. Unchanged indices pass through verbatim. A fragment that can't be re-anchored this
     * layout is DROPPED — never removes any other drawing, since removal is applied once at the end from
     * a fixed set of indices, not by mutating the list while iterating.
     */
    fun reanchor(
        drawings: List<DrawingAnchorWire>,
        changedIndices: List<Int>,
        scoreHandle: Long,
    ): List<DrawingAnchorWire> {
        if (drawings.isEmpty() || changedIndices.isEmpty()) return drawings

        // Recompute display transforms for THIS layer (post-erase `drawings`): fragments inherited the
        // parent's anchor, so the transform positionally aligned with the parent no longer applies to them
        // — this call derives the transform for each fragment's OWN (inherited-for-now) anchor identity.
        val identities = drawings.map {
            ResolvedAnchorWire(it.measureIndex, it.tickInMeasure, it.partIndex, it.staffIndexInPart, it.dxSp, it.verticalOffsetSp)
        }
        val refBytes = SheetMusicJNI.nativeAnchorReferencePoint(
            scoreHandle,
            encodeWireArray(identities, ResolvedAnchorWireCodec::encodePayload),
        )
        if (refBytes.isEmpty()) return drawings

        val transformsBytes = ReaderAnnotationJNI.displayTransforms(
            encodeWireArray(drawings, DrawingAnchorWireCodec::encodePayload),
            refBytes,
        )
        if (transformsBytes.isEmpty()) return drawings
        val transforms = decodeWireArray(transformsBytes, StrokeTransformWireCodec::decodePayload)

        val result = drawings.toMutableList()
        val dropped = HashSet<Int>()
        for (j in changedIndices) {
            val drawing = drawings.getOrNull(j) ?: continue

            // `sp == 0` means this anchor can't currently place (unresolved this layout, e.g. mid-reflow) —
            // NOT a failure. Leave the fragment as-is with its inherited anchor rather than drop it; the
            // next layout pass gets another chance to re-anchor it.
            val t = transforms.getOrNull(j)
            if (t == null || t.sp == 0.0) continue

            // `place` takes ONE `StrokeTransformWire`'s bytes, encoded standalone (`StrokeTransformWireCodec
            // .encode`, the mirror of Swift's `StrokeTransformWire(decoding:)`) — NOT `encodeWireArray`. The
            // array framing is for the batched anchor-ref/display-transform calls only; `place` and
            // `capture` (see `AnnotationCaptureController`) both take single-wire standalone bytes.
            val docFink = ReaderAnnotationJNI.place(drawing.encodedDrawing, StrokeTransformWireCodec.encode(t))
            if (docFink.isEmpty()) {
                dropped += j // unplaceable — drop only this fragment
                continue
            }

            // Rebuild the document-mm androidx.ink Stroke exactly as `computePlacement` does, so the
            // recapture below sees the same geometry the layer would render. `docFink` was just produced by
            // `place` from `drawing.encodedDrawing` (itself already round-tripped through the same InkStroke
            // codec one call earlier), so an empty decode here is practically unreachable — but if it ever
            // happens, KEEP the fragment with its inherited anchor rather than delete the user's ink over a
            // decode hiccup. Only `place` returning empty (unplaceable) or `capture` returning null
            // (unresolvable) are real drop cases.
            val rawBytes = ReaderAnnotationJNI.decodeInkStroke(docFink)
            if (rawBytes.isEmpty()) continue
            val rw = RawInkStrokeWireCodec.decode(rawBytes)
            val brush = InkBrushMapping.brushFor(rw.tool.toInt(), rw.colorRGBA.toLong(), rw.baseWidthSp.toFloat())
            val stroke = InkStrokeSerialization.toStroke(rawBytes, brush)

            // Run the fragment through the SAME capture pipeline a fresh wet stroke uses, so it gets its
            // own independent anchor. Null means off-staff / unresolvable — drop only this fragment, never
            // the rest of the layer.
            val recaptured = AnnotationCaptureController.capture(
                stroke,
                rw.tool.toInt(),
                rw.colorRGBA.toLong(),
                rw.baseWidthSp.toFloat(),
                scoreHandle,
            )
            if (recaptured != null) {
                result[j] = recaptured
            } else {
                dropped += j
            }
        }

        if (dropped.isEmpty()) return result
        return result.filterIndexed { index, _ -> index !in dropped }
    }
}
