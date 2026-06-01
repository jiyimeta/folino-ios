import Foundation

/// Metadata extracted from a score file at load time. Distinct from `ScoreItem` because the gateway runs before the
/// file is added to the library and therefore has no `ScoreItemID` or persistent state yet.
public struct ScoreFileSummary: Hashable, Sendable {
    public var title: String?
    public var subtitle: String?
    public var composer: String?
    public var arranger: String?
    public var lyricist: String?
    public var copyright: String?
    public var instrumentationSummary: String
    public var lengthBeats: Int
    public var defaultTempoBpm: Int
    public var primaryKey: String?

    public init(
        title: String?,
        subtitle: String? = nil,
        composer: String?,
        arranger: String? = nil,
        lyricist: String? = nil,
        copyright: String? = nil,
        instrumentationSummary: String,
        lengthBeats: Int,
        defaultTempoBpm: Int,
        primaryKey: String?,
    ) {
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.arranger = arranger
        self.lyricist = lyricist
        self.copyright = copyright
        self.instrumentationSummary = instrumentationSummary
        self.lengthBeats = lengthBeats
        self.defaultTempoBpm = defaultTempoBpm
        self.primaryKey = primaryKey
    }
}

/// Bridges `swift-sheet-music`'s format I/O modules into Domain. The Infrastructure implementation wraps
/// `SheetMusicMSCX`, `SheetMusicMusicXML`, and `SheetMusicMIDI` behind this single protocol so Features only depend on
/// Domain.
public protocol ScoreFileGateway: Sendable {
    /// Best-effort format detection from filename. Should agree with `ScoreFormat.detect(filename:)`.
    func detectFormat(fileName: String) -> ScoreFormat?

    /// Load only the lightweight summary (no full notation tree). Used by the importer for the prepare step.
    ///
    /// Throws `DomainError.unsupportedFormat` for unknown extensions (PDF included — `.pdf` is not a `ScoreFormat` case
    /// in v1).
    func loadFileMetadata(fileURL: URL) async throws -> ScoreFileSummary

    /// Parse a score file into the in-memory `Score` plus a transient summary.
    ///
    /// Throws `DomainError.unsupportedFormat` for unknown extensions.
    func loadScore(fileURL: URL) async throws -> (score: Score, summary: ScoreFileSummary)

    /// Write a `Score` to disk in the requested format.
    ///
    /// v1 throws `DomainError.unsupportedFormat` for every format — `swift-sheet-music` does not yet expose a Score →
    /// MSCX/MSCZ/MusicXML serializer. The method exists on the protocol so Editor can fill it in without touching
    /// consumers.
    func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) async throws
}
