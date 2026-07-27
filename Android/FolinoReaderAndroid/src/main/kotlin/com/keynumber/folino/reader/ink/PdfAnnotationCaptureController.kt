package com.keynumber.folino.reader.ink

import androidx.ink.strokes.Stroke
import com.keynumber.folino.reader.DrawingAnchorWire
import com.keynumber.folino.reader.DrawingAnchorWireCodec
import com.keynumber.folino.reader.PageFrameWire
import com.keynumber.folino.reader.PageFrameWireCodec
import com.keynumber.folino.reader.PointMmWireCodec
import com.keynumber.folino.reader.ReaderAnnotationJNI

/**
 * Turns a finished androidx.ink [Stroke] into a persistable `.page`-anchored [DrawingAnchorWire] — the PDF
 * page-anchor sibling of [AnnotationCaptureController] (musical anchors). All math is in shared Swift
 * (`PageAnchoringCore`, reached via [ReaderAnnotationJNI]'s PDF entry points); this only sequences the
 * calls, plus (for vertical mode) resolves which page the stroke's own centroid lands on — there is no
 * ssm round trip for a page anchor, so unlike [AnnotationCaptureController] the page is either already
 * known (paged mode: the single visible page) or resolved from pure Kotlin geometry the caller already
 * has (vertical mode: [PdfVerticalLayout.pageIndexForY] against the stroke's own representative point).
 */
object PdfAnnotationCaptureController {
    /**
     * Capture a stroke already known to belong to [pageIndex] — paged mode's own single visible page.
     * Null when the stroke doesn't decode or [pageFrame] has non-positive width (see
     * `nativePdfAnnotationCapture`'s own contract).
     */
    fun capture(
        stroke: Stroke,
        tool: Int,
        colorRGBA: Long,
        baseWidthSp: Float,
        pageIndex: Int,
        pageFrame: PageFrameWire,
    ): DrawingAnchorWire? {
        val rawBytes = InkStrokeSerialization.toRawWireBytes(stroke, tool, colorRGBA, baseWidthSp)
        val fink = ReaderAnnotationJNI.encodeInkStroke(rawBytes)
        if (fink.isEmpty()) return null
        return captureFink(fink, pageIndex, pageFrame)
    }

    /**
     * Vertical mode: resolve which page the stroke belongs to from its own representative point (bbox
     * center of its samples, the same point [ReaderAnnotationJNI.representativePoint] computes for the
     * musical path) before capturing. [resolvePage] maps that point's Column-local Y (the same coordinate
     * space [PdfVerticalScore]'s own page frames are expressed in) to `(pageIndex, pageFrame)` — the
     * caller supplies [PdfVerticalLayout.pageIndexForY] plus a frame lookup, so this stays independent of
     * that surface's own Compose state. Null if the stroke doesn't decode, its representative point
     * doesn't resolve, or [resolvePage] has no frame for the page it lands on.
     */
    fun captureResolvingPage(
        stroke: Stroke,
        tool: Int,
        colorRGBA: Long,
        baseWidthSp: Float,
        resolvePage: (columnLocalY: Float) -> Pair<Int, PageFrameWire>?,
    ): DrawingAnchorWire? {
        val rawBytes = InkStrokeSerialization.toRawWireBytes(stroke, tool, colorRGBA, baseWidthSp)
        val fink = ReaderAnnotationJNI.encodeInkStroke(rawBytes)
        if (fink.isEmpty()) return null

        val pointBytes = ReaderAnnotationJNI.representativePoint(fink)
        if (pointBytes.isEmpty()) return null
        val point = PointMmWireCodec.decode(pointBytes)

        val (pageIndex, pageFrame) = resolvePage(point.yMm.toFloat()) ?: return null
        return captureFink(fink, pageIndex, pageFrame)
    }

    private fun captureFink(fink: ByteArray, pageIndex: Int, pageFrame: PageFrameWire): DrawingAnchorWire? {
        val drawingBytes = ReaderAnnotationJNI.pdfCapture(fink, pageIndex, PageFrameWireCodec.encode(pageFrame))
        if (drawingBytes.isEmpty()) return null
        return DrawingAnchorWireCodec.decode(drawingBytes)
    }
}
