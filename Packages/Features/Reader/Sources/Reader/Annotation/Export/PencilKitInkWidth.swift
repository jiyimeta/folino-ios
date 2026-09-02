import CoreGraphics
import PencilKit

/// How wide PencilKit draws a stroke of a given point `size`, per ink, and the inverse.
///
/// Measured on the live `PKCanvasView` in the simulator (`docs/engineering/crdt-ink-format/tools/PKProbe`) and
/// identical in `PKDrawing.image(from:scale:)` on iOS and macOS: the width is a fixed function of the point size, in
/// the drawing's own units, at any zoom — a zoomed canvas scales both. `force` plays no part; every ink measured
/// identical at 0, 0.5 and 1.
///
/// The constant terms are what make one stroke look different in different places. A pen of size `s` is `2s − 4`
/// wide *in content units*, so the same stroke is thinner in a coordinate space whose unit is larger. folino's
/// reader draws in document units (a staff space is `staffSize / 4` of them), Apple's markup draws the exported
/// archive in canvas units (4/3 of a page point) and scales the result onto the page. The export uses these two
/// functions to make the archive render, on the page, the width the reader showed on screen.
enum PencilKitInkWidth {
    /// Rendered width for a point of `size`, both in the same units.
    static func renderedWidth(ink: PKInkingTool.InkType, size: CGFloat) -> CGFloat {
        let width: CGFloat = switch ink {
        case .pen, .monoline: 2 * size - 4
        case .pencil: 2 * size - 1
        case .marker: size / 2
        case .fountainPen: size / 2 - 0.7
        case .watercolor: 1.7 * size
        case .crayon: 1.85 * size
        @unknown default: size
        }
        return max(0, width)
    }

    /// The point size that renders `width` wide, both in the same units. Inverse of `renderedWidth`.
    static func size(forRenderedWidth width: CGFloat, ink: PKInkingTool.InkType) -> CGFloat {
        let size: CGFloat = switch ink {
        case .pen, .monoline: (width + 4) / 2
        case .pencil: (width + 1) / 2
        case .marker: width * 2
        case .fountainPen: (width + 0.7) * 2
        case .watercolor: width / 1.7
        case .crayon: width / 1.85
        @unknown default: width
        }
        return max(0, size)
    }
}
