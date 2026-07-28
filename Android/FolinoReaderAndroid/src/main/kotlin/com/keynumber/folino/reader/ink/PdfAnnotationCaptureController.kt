package com.keynumber.folino.reader.ink

import androidx.ink.strokes.Stroke
import com.keynumber.folino.reader.DrawingAnchorWire
import com.keynumber.folino.reader.DrawingAnchorWireCodec
import com.keynumber.folino.reader.PageFrameWire
import com.keynumber.folino.reader.PageFrameWireCodec
import com.keynumber.folino.reader.PageFramesWire
import com.keynumber.folino.reader.PageFramesWireCodec
import com.keynumber.folino.reader.ReaderAnnotationJNI

/**
 * Turns a finished androidx.ink [Stroke] into a persistable `.page`-anchored [DrawingAnchorWire] — the PDF
 * page-anchor sibling of [AnnotationCaptureController] (musical anchors). All math is in shared Swift
 * (`PageAnchoringCore`, reached via [ReaderAnnotationJNI]'s PDF entry points), including WHICH page a
 * stroke belongs to: [captureResolvingPage] (vertical mode) delegates the centroid → page decision — and
 * its inter-page-gap fallback — to `PageAnchoringCore.capture(strokes:pageFrames:)` via
 * `nativePdfAnnotationCaptureResolvingPage`, so this object carries none of that geometry itself. [capture]
 * (paged mode) needs no such resolve at all: the single visible page is already known.
 */
internal object PdfAnnotationCaptureController {
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
        val drawingBytes = ReaderAnnotationJNI.pdfCapture(fink, pageIndex, PageFrameWireCodec.encode(pageFrame))
        if (drawingBytes.isEmpty()) return null
        return DrawingAnchorWireCodec.decode(drawingBytes)
    }

    /**
     * Vertical mode: resolve which page the stroke belongs to from its own representative point (bbox
     * center of its samples) against [pageFrames] — the whole document's current raster page layout, the
     * SAME array `resolveDisplayTransforms` sends to `nativePdfAnnotationDisplayTransforms`. Null if the
     * stroke doesn't decode or its centroid doesn't resolve to any page (an empty [pageFrames]).
     */
    fun captureResolvingPage(
        stroke: Stroke,
        tool: Int,
        colorRGBA: Long,
        baseWidthSp: Float,
        pageFrames: List<PageFrameWire>,
    ): DrawingAnchorWire? {
        val rawBytes = InkStrokeSerialization.toRawWireBytes(stroke, tool, colorRGBA, baseWidthSp)
        val fink = ReaderAnnotationJNI.encodeInkStroke(rawBytes)
        if (fink.isEmpty()) return null

        val drawingBytes = ReaderAnnotationJNI.pdfCaptureResolvingPage(
            fink,
            PageFramesWireCodec.encode(PageFramesWire(pageFrames)),
        )
        if (drawingBytes.isEmpty()) return null
        return DrawingAnchorWireCodec.decode(drawingBytes)
    }
}
