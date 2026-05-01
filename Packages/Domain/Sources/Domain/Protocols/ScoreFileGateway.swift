import Foundation

/// Metadata extracted from a score file at load time. Distinct from
/// `ScoreItem` because the gateway runs before the file is added to the
/// library and therefore has no `ScoreItemID` or persistent state yet.
public struct ScoreFileSummary: Hashable, Sendable {
    public var title: String?
    public var composer: String?
    public var instrumentationSummary: String
    public var lengthBeats: Int
    public var defaultTempoBpm: Int
    public var primaryKey: String?

    public init(
        title: String?,
        composer: String?,
        instrumentationSummary: String,
        lengthBeats: Int,
        defaultTempoBpm: Int,
        primaryKey: String?
    ) {
        self.title = title
        self.composer = composer
        self.instrumentationSummary = instrumentationSummary
        self.lengthBeats = lengthBeats
        self.defaultTempoBpm = defaultTempoBpm
        self.primaryKey = primaryKey
    }
}

/// Bridges `swift-sheet-music`'s format I/O modules into Domain. The
/// Infrastructure implementation wraps `SheetMusicMSCX`, `SheetMusicMusicXML`,
/// `SheetMusicMIDI`, and `SheetMusicPDF` behind this single protocol so
/// Features only depend on Domain.
public protocol ScoreFileGateway: Sendable {
    /// Best-effort format detection from filename. Should agree with
    /// `ScoreFormat.detect(filename:)`.
    func detectFormat(fileName: String) -> ScoreFormat?

    /// Parse a score file into the in-memory `Score` plus a transient summary.
    func loadScore(fileURL: URL) async throws -> (score: Score, summary: ScoreFileSummary)

    /// Write a `Score` to disk in the requested format.
    func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) async throws
}
