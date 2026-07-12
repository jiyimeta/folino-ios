@testable import Domain
import Foundation
import Testing

struct InkStrokeCodecTests {
    private func sample() -> InkStroke {
        InkStroke(
            tool: .marker,
            colorRGBA: 0xFF33_66CC,
            baseWidthSp: 1.75,
            opacity: 0.6,
            x: [0, 0.5, 1.25],
            y: [0, -0.3, 0.9],
            width: [1.75, 1.8, 1.6],
            force: [0.2, 0.5, 0.4],
            azimuth: [],
            altitude: [],
            timeMillis: [0, 8, 17],
        )
    }

    @Test func `round trips all fields`() throws {
        let original = sample()
        let data = InkStrokeCodec.encode(original)
        let decoded = try InkStrokeCodec.decode(data)
        #expect(decoded == original)
    }

    @Test func `sniffs own magic`() {
        let data = InkStrokeCodec.encode(sample())
        #expect(InkStrokeCodec.isInkStroke(data))
    }

    @Test func `rejects foreign bytes`() {
        // A PKDrawing archive begins with a NSKeyedArchiver "bplist" signature, never the InkStroke magic.
        let foreign = Data("bplist00foobar".utf8)
        #expect(!InkStrokeCodec.isInkStroke(foreign))
        #expect(throws: InkStrokeCodec.InkStrokeCodecError.self) { try InkStrokeCodec.decode(foreign) }
    }

    @Test func `handles empty optional channels`() throws {
        var s = sample()
        s = InkStroke(
            tool: .pen, colorRGBA: 0xFF00_0000, baseWidthSp: 1, opacity: 1,
            x: [0, 1], y: [0, 1], width: [1, 1], force: [], azimuth: [], altitude: [], timeMillis: [],
        )
        let decoded = try InkStrokeCodec.decode(InkStrokeCodec.encode(s))
        #expect(decoded == s)
    }
}
