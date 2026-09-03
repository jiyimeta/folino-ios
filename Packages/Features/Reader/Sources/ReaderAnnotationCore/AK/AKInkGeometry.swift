import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The rectangles Apple's ink annotation is placed by, all derived from the drawing's own bounds.
///
/// Three boxes describe the same area and must agree to well under a tenth of a point: the bounds PencilKit
/// computes for the drawing (`PKDrawing.bounds`, which is what AnnotationKit recomputes and compares against),
/// the archive's `rectangle`, and the PDF annotation's `/Rect`. A disagreement of about 0.1pt -- which is all it
/// takes to use A4's nominal height against a page that is really 842 points -- makes Apple's markup discard the
/// annotation in silence. It neither erases nor selects, and only the appearance stream keeps it visible, so the
/// failure looks like nothing happening at all.
///
/// A padding formula of our own was tried first and cost a device round: a marker's rendered extent is not the
/// point extent plus half the width, and the mark landed tens of points away from where the bounds said. So the
/// bounds come from PencilKit and everything else is a function of them.
public enum AKInkGeometry {
    /// Page points to canvas units. Apple's samples put a 595 x 842 page on a 792.8 x 1122.1 canvas, which is the
    /// 96-against-72 ratio screens use. Any consistent scale is accepted -- it cancels out of the archive rectangle
    /// -- so this stays with the one every accepted device test used rather than inventing another.
    public static let canvasScale: CGFloat = 96.0 / 72.0

    public static func drawingSize(pageSize: CGSize) -> CGSize {
        CGSize(width: pageSize.width * canvasScale, height: pageSize.height * canvasScale)
    }

    /// The archive rectangle, page space with y up, for a drawing whose `bounds` are in canvas units with a
    /// top-left origin and y down. The scale is the reciprocal of `canvasScale`, so the rectangle is the bounds
    /// divided back into page points and flipped about the page height.
    public static func archiveRect(canvasBounds: CGRect, pageHeight: CGFloat) -> CGRect {
        let q = 1 / canvasScale
        return CGRect(
            x: canvasBounds.minX * q, y: pageHeight - canvasBounds.maxY * q,
            width: canvasBounds.width * q, height: canvasBounds.height * q,
        )
    }

    /// Measured at exactly one point on every edge, across every Apple sample, to four decimals. Setting `/Rect`
    /// equal to the archive rectangle instead — which is what it looks like it should be — is rejected.
    public static func annotationRect(_ archiveRect: CGRect) -> CGRect {
        CGRect(
            x: archiveRect.minX - 1, y: archiveRect.minY - 1,
            width: archiveRect.width + 2, height: archiveRect.height + 2,
        )
    }
}
