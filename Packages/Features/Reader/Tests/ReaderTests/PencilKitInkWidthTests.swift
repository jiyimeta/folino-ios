import CoreGraphics
import PencilKit
@testable import Reader
import Testing

/// The measured curves, pinned, and the inverse that the export solves sizes with.
@Suite("PencilKit ink width")
struct PencilKitInkWidthTests {
    @Test
    func `the pen curve matches the simulator measurements`() {
        // Measured on the live PKCanvasView at sizes 4 / 8 / 16: 4 / 12 / 28.
        #expect(PencilKitInkWidth.renderedWidth(ink: .pen, size: 4) == 4)
        #expect(PencilKitInkWidth.renderedWidth(ink: .pen, size: 8) == 12)
        #expect(PencilKitInkWidth.renderedWidth(ink: .pen, size: 16) == 28)
        #expect(PencilKitInkWidth.renderedWidth(ink: .monoline, size: 5.25) == 6.5)
        #expect(PencilKitInkWidth.renderedWidth(ink: .marker, size: 22.7) == 11.35)
        #expect(PencilKitInkWidth.renderedWidth(ink: .pen, size: 1) == 0, "never negative")
    }

    @Test
    func `size(forRenderedWidth:) inverts renderedWidth for every ink`() {
        let inks: [PKInkingTool.InkType] = [.pen, .monoline, .pencil, .marker, .fountainPen, .watercolor, .crayon]
        for ink in inks {
            for size in [3.0, 5.25, 8.0, 22.7] as [CGFloat] {
                let width = PencilKitInkWidth.renderedWidth(ink: ink, size: size)
                #expect(abs(PencilKitInkWidth.size(forRenderedWidth: width, ink: ink) - size) < 1e-9, "\(ink) \(size)")
            }
        }
    }
}
