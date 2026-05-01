@testable import Domain
import Foundation
import Testing

@Suite struct AnnotationLayerTests {
    private func anchor(system: Int = 0) -> MusicalAnchor {
        MusicalAnchor(systemIndex: system, normalizedFrame: UnitRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
    }

    @Test func emptyLayerHasNoEntries() {
        let layer = AnnotationLayer(
            id: AnnotationLayerID(),
            scoreItemID: ScoreItemID(),
            drawings: [],
            textBoxes: [],
            updatedAt: Date()
        )
        #expect(layer.drawings.isEmpty)
        #expect(layer.textBoxes.isEmpty)
    }

    @Test func roundTripsThroughCodable() throws {
        let layer = AnnotationLayer(
            id: AnnotationLayerID(),
            scoreItemID: ScoreItemID(),
            drawings: [
                DrawingAnchor(id: AnnotationID(), anchor: anchor(system: 0), encodedDrawing: Data([0xDE, 0xAD])),
                DrawingAnchor(id: AnnotationID(), anchor: anchor(system: 3), encodedDrawing: Data([0xBE, 0xEF])),
            ],
            textBoxes: [
                TextBoxAnchor(id: AnnotationID(), anchor: anchor(system: 1), text: "fingering"),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(AnnotationLayer.self, from: data)
        #expect(decoded == layer)
    }

    @Test func drawingAnchorIsIdentifiable() {
        let id = AnnotationID()
        let d = DrawingAnchor(id: id, anchor: anchor(), encodedDrawing: Data())
        #expect(d.id == id)
    }

    @Test func textBoxAnchorIsIdentifiable() {
        let id = AnnotationID()
        let t = TextBoxAnchor(id: id, anchor: anchor(), text: "x")
        #expect(t.id == id)
    }
}
