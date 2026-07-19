import Domain
import Foundation
import ReaderAnnotationCore
import Testing

@Suite("AnnotationLayerCodec")
struct AnnotationLayerCodecTests {
    private func drawing(dxSp: Double) -> DrawingAnchor {
        DrawingAnchor(
            kind: .musical(MusicalAnchor(
                measureIndex: 1, tickInMeasure: 0, partIndex: 0,
                staffIndexInPart: 0, dxSp: dxSp, verticalOffsetSp: -1,
            )),
            encodedDrawing: Data([0x46, 0x49, 0x4E, 0x4B, 0x01]),
        )
    }

    @Test
    func `encode/decode round-trips drawings and preserves the {drawings,textBoxes} shape`() throws {
        let d = drawing(dxSp: 0.5)
        let bytes = AnnotationLayerCodec.encode(drawings: [d], textBoxes: [])
        let json = try #require(String(data: bytes, encoding: .utf8))
        #expect(json.contains("\"drawings\""))
        #expect(json.contains("\"textBoxes\""))

        let back = try #require(AnnotationLayerCodec.decode(bytes))
        #expect(back.drawings == [d])
        #expect(back.textBoxes.isEmpty)
    }

    @Test
    func `decode returns nil for non-layer bytes`() {
        #expect(AnnotationLayerCodec.decode(Data([0x00, 0x01, 0x02])) == nil)
        #expect(AnnotationLayerCodec.decode(Data()) == nil)
    }

    @Test
    func `a decoded drawing keeps its identity and FINK bytes for a byte-stable round-trip`() throws {
        let a = drawing(dxSp: 1.25)
        let b = drawing(dxSp: -2)
        let bytes = AnnotationLayerCodec.encode(drawings: [a, b], textBoxes: [])
        let back = try #require(AnnotationLayerCodec.decode(bytes))
        #expect(back.drawings.count == 2)
        #expect(back.drawings[0].id == a.id)
        #expect(back.drawings[1].id == b.id)
        #expect(back.drawings[0].encodedDrawing == a.encodedDrawing)
    }
}
