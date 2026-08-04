import Foundation

/// The cross-app hand-off descriptor a sibling app writes to `IncomingScores/<token>/intent.json`.
///
/// Deliberately *not* `IncomingShareIntent`: that one is folino's private Share-Extension format (`UUID` token,
/// playlist fields, default `Date` encoding). This is the published cross-app contract — a `String` token, an
/// ISO-8601 `createdAt`, the originating app, and no playlist concept. The property names are the JSON keys, matching
/// the default key strategy the sibling encodes with.
public struct IncomingScoreIntent: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let token: String
    public let createdAt: Date
    /// Originating app, e.g. `"vocaltuner"`. Becomes the `source` of the `score_imported` analytics event.
    public let source: String
    public let openAfter: Bool
    public let files: [File]

    public init(
        schemaVersion: Int,
        token: String,
        createdAt: Date,
        source: String,
        openAfter: Bool,
        files: [File],
    ) {
        self.schemaVersion = schemaVersion
        self.token = token
        self.createdAt = createdAt
        self.source = source
        self.openAfter = openAfter
        self.files = files
    }

    public struct File: Codable, Sendable, Equatable {
        /// Path of the staged bytes relative to the token directory, e.g. `files/Etude.musicxml`.
        public let relativePath: String
        public let originalName: String
        /// Advisory format hint (`ScoreFormat` raw value). Optional and unused by the import, which re-derives the
        /// real format from the filename extension — a mislabelled hint must not decide how a file is parsed.
        public let format: String?

        public init(relativePath: String, originalName: String, format: String? = nil) {
            self.relativePath = relativePath
            self.originalName = originalName
            self.format = format
        }
    }

    /// Decoder matching the contract. A plain `JSONDecoder` reads `createdAt` as a numeric
    /// `timeIntervalSinceReferenceDate` and fails outright on the ISO-8601 string the sibling writes.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encoder matching the contract — the inverse of `decoder()`, so `createdAt` is written as the ISO-8601 string
    /// a sibling expects rather than a bare number. Used by `OutgoingScoreStager` when folino stages a hand-off, and
    /// by tests round-tripping against the exact bytes the sibling produces.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
