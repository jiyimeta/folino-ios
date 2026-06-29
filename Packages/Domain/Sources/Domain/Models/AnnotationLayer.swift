import Foundation

/// A free-hand stroke (or stroke group) anchored to a position inside a document. `encodedDrawing` is opaque to
/// Domain — the Reader decodes it as a `PKDrawing`. `kind` selects musical (score) vs page (PDF) anchoring.
public struct DrawingAnchor: Hashable, Codable, Sendable, Identifiable {
    public let id: AnnotationID
    public var kind: DrawingAnchorKind
    public var encodedDrawing: Data

    public init(id: AnnotationID = AnnotationID(), kind: DrawingAnchorKind, encodedDrawing: Data) {
        self.id = id
        self.kind = kind
        self.encodedDrawing = encodedDrawing
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case encodedDrawing
        case anchor // legacy: a top-level MusicalAnchor written before page anchoring existed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(AnnotationID.self, forKey: .id)
        encodedDrawing = try c.decode(Data.self, forKey: .encodedDrawing)
        if let kind = try c.decodeIfPresent(DrawingAnchorKind.self, forKey: .kind) {
            self.kind = kind
        } else {
            // Pre-PDF data stored the MusicalAnchor directly under "anchor"; map it to .musical.
            let legacy = try c.decode(MusicalAnchor.self, forKey: .anchor)
            kind = .musical(legacy)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(encodedDrawing, forKey: .encodedDrawing)
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
