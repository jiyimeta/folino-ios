import Foundation

/// A free-hand stroke (or stroke group) anchored to a position inside a system.
/// `encodedDrawing` is opaque to Domain — the Reader feature decodes it as a
/// `PKDrawing`. Domain does not depend on PencilKit.
struct DrawingAnchor: Hashable, Codable, Identifiable {
    let id: AnnotationID
    var anchor: MusicalAnchor
    var encodedDrawing: Data

    init(id: AnnotationID = AnnotationID(), anchor: MusicalAnchor, encodedDrawing: Data) {
        self.id = id
        self.anchor = anchor
        self.encodedDrawing = encodedDrawing
    }
}

/// A user-typed text box anchored to a position inside a system. Plain text
/// only — no rich formatting in v1.
struct TextBoxAnchor: Hashable, Codable, Identifiable {
    let id: AnnotationID
    var anchor: MusicalAnchor
    var text: String

    init(id: AnnotationID = AnnotationID(), anchor: MusicalAnchor, text: String) {
        self.id = id
        self.anchor = anchor
        self.text = text
    }
}

/// All annotations for a single score. There is at most one `AnnotationLayer`
/// per `ScoreItem`.
struct AnnotationLayer: Hashable, Codable, Identifiable {
    let id: AnnotationLayerID
    let scoreItemID: ScoreItemID
    var drawings: [DrawingAnchor]
    var textBoxes: [TextBoxAnchor]
    var updatedAt: Date

    init(
        id: AnnotationLayerID = AnnotationLayerID(),
        scoreItemID: ScoreItemID,
        drawings: [DrawingAnchor],
        textBoxes: [TextBoxAnchor],
        updatedAt: Date,
    ) {
        self.id = id
        self.scoreItemID = scoreItemID
        self.drawings = drawings
        self.textBoxes = textBoxes
        self.updatedAt = updatedAt
    }
}
