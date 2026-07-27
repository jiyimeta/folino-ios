import Domain
@testable import FolinoReaderJNI
import Foundation
import Testing

struct PdfAnnotationBridgeTests {
    private func frames() -> Data {
        PageFramesWire(frames: [
            PageFrameWire(x: 0, y: 0, width: 100, height: 200),
            PageFrameWire(x: 0, y: 220, width: 100, height: 200),
        ]).encodeToData()
    }

    @Test func `capture produces A page anchor`() throws {
        // A two-point stroke whose centroid lands on page 1 (y 220...420).
        let stroke = RawInkStrokeWire(
            tool: 0, colorRGBA: 0xFF00_00FF, baseWidthSp: 1, opacity: 1,
            x: [40, 60], y: [300, 340], width: [1, 1], force: [1, 1], timeMillis: [0, 16],
        )
        let wire = try DrawingAnchorWire(decoding: nativePdfAnnotationCapture(
            strokeBytes: nativeEncodeInkStroke(rawBytes: stroke.encodeToData()),
            pageIndex: 1,
            pageFrameBytes: PageFrameWire(x: 0, y: 220, width: 100, height: 200).encodeToData(),
        ))
        #expect(wire.anchorKind == 1)
        #expect(wire.pageIndex == 1)
        #expect(!wire.encodedDrawing.isEmpty)
    }

    @Test func `display transform scales by page width and translates to the origin`() throws {
        let drawing = DrawingAnchorWire.page(pageIndex: 1, encodedDrawing: Data([1, 2, 3]))
        let out = nativePdfAnnotationDisplayTransforms(
            drawingsBytes: [drawing].encodeToData(), pageFramesBytes: frames(),
        )
        let transforms = try [StrokeTransformWire](decoding: out)
        #expect(transforms.count == 1)
        #expect(transforms[0].sp == 100)
        #expect(transforms[0].px == 0)
        #expect(transforms[0].py == 220)
    }

    @Test func `anchor on A missing page is marked unplaceable`() throws {
        let drawing = DrawingAnchorWire.page(pageIndex: 9, encodedDrawing: Data([1]))
        let transforms = try [StrokeTransformWire](decoding: nativePdfAnnotationDisplayTransforms(
            drawingsBytes: [drawing].encodeToData(), pageFramesBytes: frames(),
        ))
        #expect(transforms[0].sp == 0)
    }

    @Test func `mismatched inputs return empty`() {
        #expect(nativePdfAnnotationDisplayTransforms(drawingsBytes: Data(), pageFramesBytes: frames()).isEmpty)
    }
}
