import Domain
import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The rectangles Apple's ink annotation is placed by, all derived from one box.
///
/// Three of them describe the same area and must agree to well under a tenth of a point: the payload's own stored
/// bounding box, the archive's `rectangle`, and the PDF annotation's `/Rect`. A disagreement of about 0.1pt --
/// which is all it takes to use A4's nominal height against a page that is really 842 points -- makes Apple's
/// markup discard the annotation in silence. It neither erases nor selects, and only the appearance stream keeps
/// it visible, so the failure looks like nothing happening at all.
///
/// Deriving them separately cannot guarantee that. So there is one box, in page-local points with a top-left
/// origin and y down, and everything else is a function of it.
public enum AKInkGeometry {
    /// Page points to canvas units. Apple's samples put a 595 x 842 page on a 792.8 x 1122.1 canvas, which is the
    /// 96-against-72 ratio screens use. Any consistent scale works -- it cancels out of the archive rectangle --
    /// so this stays with the one Apple ships rather than inventing another.
    static let canvasScale: CGFloat = 96.0 / 72.0

    public static func drawingSize(pageSize: CGSize) -> CGSize {
        CGSize(width: pageSize.width * canvasScale, height: pageSize.height * canvasScale)
    }

    /// The extent of every point, grown by half the widest sample (the ink's own reach) plus a point of
    /// anti-aliasing slack. `nil` when there are no points to bound.
    public static func inkBox(of strokes: [InkStroke]) -> CGRect? {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        var widest: CGFloat = 0
        var any = false
        for stroke in strokes {
            for i in stroke.x.indices where i < stroke.y.count {
                any = true
                minX = min(minX, CGFloat(stroke.x[i]))
                maxX = max(maxX, CGFloat(stroke.x[i]))
                minY = min(minY, CGFloat(stroke.y[i]))
                maxY = max(maxY, CGFloat(stroke.y[i]))
                if i < stroke.width.count {
                    widest = max(widest, CGFloat(stroke.width[i]))
                }
            }
            widest = max(widest, CGFloat(stroke.baseWidthSp))
        }
        guard any else { return nil }
        let pad = widest / 2 + 1
        return CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
    }

    static func canvasBox(_ inkBox: CGRect) -> CGRect {
        CGRect(
            x: inkBox.minX * canvasScale, y: inkBox.minY * canvasScale,
            width: inkBox.width * canvasScale, height: inkBox.height * canvasScale,
        )
    }

    /// Page space, y up. The canvas scale cancels — `sx` is the reciprocal of the scale the box was multiplied by
    /// — so this is the ink box with its y axis flipped about the page height, and the test pins that.
    public static func archiveRect(_ inkBox: CGRect, pageHeight: CGFloat) -> CGRect {
        CGRect(x: inkBox.minX, y: pageHeight - inkBox.maxY, width: inkBox.width, height: inkBox.height)
    }

    /// Measured at exactly one point on every edge, across all eight samples, to four decimals. Setting `/Rect`
    /// equal to the archive rectangle instead — which is what it looks like it should be — is rejected.
    public static func annotationRect(_ archiveRect: CGRect) -> CGRect {
        CGRect(
            x: archiveRect.minX - 1, y: archiveRect.minY - 1,
            width: archiveRect.width + 2, height: archiveRect.height + 2,
        )
    }
}
