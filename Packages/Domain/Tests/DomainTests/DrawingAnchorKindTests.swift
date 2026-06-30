@testable import Domain
import Foundation
import Testing

struct DrawingAnchorKindTests {
    private func musicalAnchor() -> MusicalAnchor {
        MusicalAnchor(
            measureIndex: 2, tickInMeasure: 480, partIndex: 0, staffIndexInPart: 1, dxSp: 1.5, verticalOffsetSp: -3,
        )
    }

    @Test func `round trips musical kind`() throws {
        let a = DrawingAnchor(kind: .musical(musicalAnchor()), encodedDrawing: Data([1, 2, 3]))
        let data = try JSONEncoder().encode(a)
        let back = try JSONDecoder().decode(DrawingAnchor.self, from: data)
        #expect(back == a)
        #expect(back.kind == .musical(musicalAnchor()))
    }

    @Test func `round trips page kind`() throws {
        let a = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 3)), encodedDrawing: Data([9]))
        let data = try JSONEncoder().encode(a)
        let back = try JSONDecoder().decode(DrawingAnchor.self, from: data)
        #expect(back == a)
        #expect(back.kind == .page(PageAnchor(pageIndex: 3)))
    }

    @Test func `decodes legacy anchor as musical`() throws {
        // Legacy on-disk shape: a top-level "anchor" MusicalAnchor and no "kind".
        let anchorJSON = "{\"measureIndex\":2,\"tickInMeasure\":480,\"partIndex\":0,"
            + "\"staffIndexInPart\":1,\"dxSp\":1.5,\"verticalOffsetSp\":-3}"
        let legacy = Data("""
        {"id":{"rawValue":"\(UUID().uuidString)"},
         "anchor":\(anchorJSON),
         "encodedDrawing":"AQID"}
        """.utf8)
        let back = try JSONDecoder().decode(DrawingAnchor.self, from: legacy)
        #expect(back.kind == .musical(musicalAnchor()))
        #expect(back.encodedDrawing == Data([1, 2, 3]))
    }

    @Test func `page anchor clamps negative`() {
        #expect(PageAnchor(pageIndex: -5).pageIndex == 0)
    }
}
