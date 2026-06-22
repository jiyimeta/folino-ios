@testable import Domain
import Foundation
import Testing

struct AnnotationLayerTests {
    private func anchor(measure: Int = 0) -> MusicalAnchor {
        MusicalAnchor(
            measureIndex: measure, tickInMeasure: 0, partIndex: 0,
            staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
    }

    @Test func `empty layer has no entries`() {
        let layer = AnnotationLayer(
            id: AnnotationLayerID(),
            scoreItemID: ScoreItemID(),
            drawings: [],
            textBoxes: [],
            updatedAt: Date(),
        )
        #expect(layer.drawings.isEmpty)
        #expect(layer.textBoxes.isEmpty)
    }

    @Test func `round trips through codable`() throws {
        let layer = AnnotationLayer(
            id: AnnotationLayerID(),
            scoreItemID: ScoreItemID(),
            drawings: [
                DrawingAnchor(id: AnnotationID(), anchor: anchor(measure: 0), encodedDrawing: Data([0xDE, 0xAD])),
                DrawingAnchor(id: AnnotationID(), anchor: anchor(measure: 3), encodedDrawing: Data([0xBE, 0xEF])),
            ],
            textBoxes: [
                TextBoxAnchor(id: AnnotationID(), anchor: anchor(measure: 1), text: "fingering"),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(AnnotationLayer.self, from: data)
        #expect(decoded == layer)
    }

    @Test func `drawing anchor is identifiable`() {
        let id = AnnotationID()
        let d = DrawingAnchor(id: id, anchor: anchor(), encodedDrawing: Data())
        #expect(d.id == id)
    }

    @Test func `text box anchor is identifiable`() {
        let id = AnnotationID()
        let t = TextBoxAnchor(id: id, anchor: anchor(), text: "x")
        #expect(t.id == id)
    }
}
