import Foundation

/// The originating file format of a score, recovered by parsing the file. Domain-pure mirror of swift-sheet-music's
/// `ScoreSource` so Features can render a source label without importing the music engine. MuseScore carries its
/// detected wire-format major version (2, 3, or 4).
public enum ScoreSourceKind: Hashable, Sendable {
    case museScore(majorVersion: Int)
    case musicXML
    case midi
    case pdf
    case unknown
}

/// Read-only metadata recovered from a score file on demand: the source format plus the human-readable credit
/// metaTags. Used by the Library's edit sheet to show the source and to pre-fill credit fields that have never been
/// edited (NULL columns). Edits are persisted to `ScoreItem`, not back into the file.
public struct ScoreFileMetadata: Hashable, Sendable {
    public let source: ScoreSourceKind
    public let composer: String?
    public let arranger: String?
    public let lyricist: String?
    public let copyright: String?

    public init(
        source: ScoreSourceKind,
        composer: String?,
        arranger: String?,
        lyricist: String?,
        copyright: String?,
    ) {
        self.source = source
        self.composer = composer
        self.arranger = arranger
        self.lyricist = lyricist
        self.copyright = copyright
    }
}

/// Parses an existing library item's on-disk file to recover its `ScoreFileMetadata`. The parse happens on demand
/// (when the edit sheet opens), mirroring how `ScoreShareService` reads `Score.source` lazily — never eagerly per
/// library row.
public protocol ScoreMetadataReading: Sendable {
    func readMetadata(for item: ScoreItem) async throws -> ScoreFileMetadata
}
