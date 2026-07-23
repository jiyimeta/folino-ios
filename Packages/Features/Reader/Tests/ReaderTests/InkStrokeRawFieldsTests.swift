import Domain
import Foundation
import ReaderAnnotationCore
import Testing

struct InkStrokeRawFieldsTests {
    @Test func `raw fields round trip through FINK`() throws {
        let raw = InkStrokeRawFields(
            tool: 0, colorRGBA: 0xFF33_66FF, baseWidthSp: 1.5, opacity: 0.5,
            x: [10, 11.5, 13], y: [20, 20.25, 21], width: [1.5, 1.625, 1.375],
            force: [0.5, 0.75, 0.625], timeMillis: [0, 8, 16],
        )
        let fink = InkStrokeCodec.encode(raw.toInkStroke())
        #expect(!fink.isEmpty)
        let back = try InkStrokeRawFields(InkStrokeCodec.decode(fink))
        #expect(back == raw)
    }

    @Test func `unknown tool falls back to pen`() {
        let raw = InkStrokeRawFields(
            tool: 99, colorRGBA: 0, baseWidthSp: 1, opacity: 1,
            x: [0], y: [0], width: [1], force: [], timeMillis: [],
        )
        #expect(raw.toInkStroke().tool == .pen)
    }
}
