package com.keynumber.folino.reader.ink

import androidx.compose.ui.geometry.Offset
import com.keynumber.folino.reader.DrawingAnchorWire
import com.keynumber.folino.reader.DrawingAnchorWireCodec
import com.keynumber.folino.reader.EraseRequestWire
import com.keynumber.folino.reader.EraseRequestWireCodec
import com.keynumber.folino.reader.EraseResultWireCodec
import com.keynumber.folino.reader.RawInkStrokeWireCodec
import com.keynumber.folino.reader.ReaderAnnotationJNI
import com.keynumber.folino.reader.StrokeTransformWireCodec

/** Phase-1 (`applyErase`) result: the layer after the cut, plus which indices are fragments that need Phase 2. */
data class EraseOutcome(val drawings: List<DrawingAnchorWire>, val changedIndices: List<Int>) {
    /**
     * Whether applying this outcome actually changes a layer of [baseSize] (the pre-erase count).
     * [changedIndices] flags only SPLIT/TRIMMED fragments — a fully-erased (dropped) stroke leaves nothing
     * in it — so a gesture that only drops strokes has an empty [changedIndices] yet a genuinely shorter
     * layer. The gesture handler must gate its publish on THIS, not on [changedIndices] alone: doing the
     * latter silently discards a pure-drop gesture, which is what made a small remnant un-erasable no matter
     * how hard the eraser scrubbed over it (a full cover is a drop, never a fragment).
     */
    fun changesLayer(baseSize: Int): Boolean = drawings.size != baseSize || changedIndices.isNotEmpty()
}

/**
 * Sequences the two-phase partial eraser. All the geometry (path-vs-stroke cut, anchor placement) lives
 * in shared Swift, reached through [ReaderAnnotationJNI] — this only wires the calls together, mirroring
 * [AnnotationDryOverlay]'s `computePlacement` (Phase 1's display-transform half) and
 * [AnnotationCaptureController] (Phase 2's per-fragment musical re-anchor).
 *
 * Why two phases instead of one native call: cutting the layer (Phase 1) is cheap and reflow-independent
 * — it only needs the CURRENT display placement to hit-test the eraser path against. But a MUSICAL
 * fragment no longer shares its parent's geometry, so it can't keep sharing the parent's anchor once the
 * score reflows; only re-running the full capture pipeline (Phase 2) on the fragment's OWN geometry gives
 * it an anchor that will track correctly. A PAGE fragment has no such problem — see [reanchor]'s own doc.
 * Splitting the phases lets the cut happen synchronously on the erase gesture while the (heavier,
 * per-fragment, musical-only) re-anchor can be batched or deferred without blocking ink.
 *
 * [applyErase]/[reanchor] both take an injected `resolveDisplayTransforms`, exactly
 * [AnnotationDryOverlay]'s own parameter of the same name and for the same reason (Task 11): a musical
 * caller closes over its `scoreHandle` and does the ssm ref-point round trip; a PDF caller closes over its
 * current page frames and calls `ReaderAnnotationJNI.pdfDisplayTransforms` directly. The Swift/JNI side
 * (`nativeAnnotationErase`, `AnnotationEraseCore.erase`) is anchor-kind-agnostic already — a fragment keeps
 * its parent's exact `DrawingAnchorKind` (same page index, or same musical identity) — so nothing here
 * duplicates that geometry; this file only needed to stop assuming every drawing is musical.
 */
object AnnotationEraseController {
    /** Wire value for a page anchor — mirrors Swift `AnchorKindWireCoding.pageAnchorKind`. Anything else
     * (including the default `0`) is musical, matching that type's own "any other value is musical" rule. */
    private const val PAGE_ANCHOR_KIND = 1

    /**
     * Phase 1: cut the layer along [pathWorld] (a polyline in the caller's own annotation world units —
     * mm for a musical caller, raster px for a PDF one; [resolveDisplayTransforms] must already agree, see
     * that parameter's own doc) with [radiusWorld] geometric radius in the same units. Fragments inherit
     * the parent drawing's anchor — they render correctly immediately but haven't been re-anchored yet
     * (that's [reanchor]). Returns null when any native step fails to decode; the caller must leave the
     * layer untouched rather than risk applying a partial cut.
     */
    fun applyErase(
        drawings: List<DrawingAnchorWire>,
        resolveDisplayTransforms: (List<DrawingAnchorWire>) -> ByteArray,
        pathWorld: List<Offset>,
        radiusWorld: Float,
    ): EraseOutcome? {
        // Nothing to erase — return null (not an empty outcome) so the caller leaves the layer untouched.
        if (drawings.isEmpty()) return null

        // Encoded once and reused below: this runs ~20x/sec during an erase drag, and re-serializing the
        // whole layer (every FINK payload included) a second time per call is pure waste.
        val encodedDrawings = encodeWireArray(drawings, DrawingAnchorWireCodec::encodePayload)

        // The erase hit-test must run in the display space the user actually saw the ink in, not the
        // anchor-relative storage space — same reason `computePlacement` resolves transforms first.
        val transformsBytes = resolveDisplayTransforms(drawings)
        if (transformsBytes.isEmpty()) return null

        // `EraseRequestWire`'s own field names (xMm/yMm/radiusMm) are the wire contract, unchanged — the
        // VALUES here are whatever world unit `pathWorld`/`radiusWorld` are in, matching what
        // `nativeAnnotationErase`'s own display-space hit test expects (the SAME space `resolveDisplayTransforms`
        // just produced).
        val request = EraseRequestWire(
            xMm = pathWorld.map { it.x.toDouble() },
            yMm = pathWorld.map { it.y.toDouble() },
            radiusMm = radiusWorld.toDouble(),
        )
        val resultBytes = ReaderAnnotationJNI.erase(
            encodedDrawings, transformsBytes, EraseRequestWireCodec.encode(request),
        )
        if (resultBytes.isEmpty()) return null

        val result = EraseResultWireCodec.decode(resultBytes)
        return EraseOutcome(result.drawings, result.changedIndices)
    }

    /**
     * Phase 2: re-anchor the fragments Phase 1 flagged in `changedIndices` (indices into the POST-erase
     * `drawings`, i.e. [EraseOutcome.drawings]). Unchanged indices pass through verbatim.
     *
     * A MUSICAL fragment gets its own independent anchor via the same capture pipeline a fresh wet stroke
     * uses (via [scoreHandle]) — its inherited anchor no longer matches its own (smaller) geometry, so a
     * future reflow could misplace it. A fragment that can't be re-anchored this layout is DROPPED — never
     * removes any other drawing, since removal is applied once at the end from a fixed set of indices, not
     * by mutating the list while iterating.
     *
     * A PAGE fragment is left exactly as Phase 1 produced it. Its stored geometry is a fraction of the
     * page's own width — reflow-invariant by construction (a PDF page never reflows) — so the slice Phase 1
     * already cut is, byte for byte, what a fresh capture of the same fragment would produce; recapturing it
     * would be a wasted round trip at best. Recapturing it via the MUSICAL pipeline below, however, would be
     * actively wrong: a page wire's musical fields are the zeroed placeholder `DrawingAnchorWire.page`
     * writes (see that type's own doc), and `nativeAnchorReferencePoint` resolving those zeros against a
     * live [scoreHandle] can silently succeed — reanchoring the fragment to whatever note sits at
     * measure 0 / tick 0 and converting a page anchor into a musical one. [scoreHandle] is `null` for a PDF
     * caller specifically so this path can never run in that context even if this check were skipped, but
     * the anchor-kind check below is the actual guard — it also protects a same-session mix (unreachable
     * today; a layer is homogeneous per surface) from ever crossing kinds.
     */
    fun reanchor(
        drawings: List<DrawingAnchorWire>,
        changedIndices: List<Int>,
        resolveDisplayTransforms: (List<DrawingAnchorWire>) -> ByteArray,
        scoreHandle: Long?,
    ): List<DrawingAnchorWire> {
        if (drawings.isEmpty() || changedIndices.isEmpty()) return drawings

        // Recompute display transforms for THIS layer (post-erase `drawings`): fragments inherited the
        // parent's anchor, so the transform positionally aligned with the parent no longer applies to them
        // — this call derives the transform for each fragment's OWN (inherited-for-now) anchor identity.
        // Only MUSICAL fragments actually consume the result (see the loop below) — computed once up front
        // regardless, since a mixed `changedIndices` batch is the common case and per-drawing branching
        // happens after this shared step, not instead of it.
        val transformsBytes = resolveDisplayTransforms(drawings)
        if (transformsBytes.isEmpty()) return drawings
        val transforms = decodeWireArray(transformsBytes, StrokeTransformWireCodec::decodePayload)

        val result = drawings.toMutableList()
        val dropped = HashSet<Int>()
        for (j in changedIndices) {
            val drawing = drawings.getOrNull(j) ?: continue

            // Page anchors are reflow-invariant — see this function's own doc for why skipping is correct,
            // not merely convenient, and why recapturing via the musical path below would corrupt it.
            if (drawing.anchorKind == PAGE_ANCHOR_KIND) continue
            // No musical score to resolve against (a PDF-only session, or Task 12 territory) — leave the
            // fragment on its inherited anchor rather than crash or guess; matches the "unresolved this
            // layout" tolerance below.
            if (scoreHandle == null) continue

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
