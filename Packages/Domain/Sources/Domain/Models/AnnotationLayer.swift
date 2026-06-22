import Foundation

/// A free-hand stroke (or stroke group) anchored to a position inside the score. `encodedDrawing` is opaque to Domain —
/// the Reader decodes it as a `PKDrawing`. Domain does not depend on PencilKit.
public struct DrawingAnchor: Hashable, Codable, Sendable, Identifiable {
    public let id: AnnotationID
    public var anchor: MusicalAnchor
    public var encodedDrawing: Data

    public init(id: AnnotationID = AnnotationID(), anchor: MusicalAnchor, encodedDrawing: Data) {
        self.id = id
        self.anchor = anchor
        self.encodedDrawing = encodedDrawing
    }
}

/// A user-typed text box anchored to a position inside the score. Plain text only — no rich formatting in v1.
public struct TextBoxAnchor: Hashable, Codable, Sendable, Identifiable {
    public let id: AnnotationID
    public var anchor: MusicalAnchor
    public var text: String

    public init(id: AnnotationID = AnnotationID(), anchor: MusicalAnchor, text: String) {
        self.id = id
        self.anchor = anchor
        self.text = text
    }
}

/// All annotations for a single score. There is at most one `AnnotationLayer` per `ScoreItem`.
public struct AnnotationLayer: Hashable, Codable, Sendable, Identifiable {
    public let id: AnnotationLayerID
    public let scoreItemID: ScoreItemID
    public var drawings: [DrawingAnchor]
    public var textBoxes: [TextBoxAnchor]
    public var updatedAt: Date

    public init(
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
