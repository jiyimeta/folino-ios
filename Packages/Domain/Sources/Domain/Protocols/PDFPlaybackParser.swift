import Foundation
import SheetMusicCore

/// A diagnostic emitted while parsing a PDF into a playable score. OMR is best-effort, so these note
/// places the importer was unsure about. There is no per-element confidence score — they are advisory
/// and may be surfaced as telemetry or used to strengthen the user-facing "parsing is imperfect" copy.
public struct PDFParseDiagnostic: Hashable, Sendable {
    public enum Severity: Hashable, Sendable { case info, warning }

    public let severity: Severity
    /// Human-readable location, e.g. "page 3, system 2, measure 17".
    public let location: String
    public let message: String

    public init(severity: Severity, location: String, message: String) {
        self.severity = severity
        self.location = location
        self.message = message
    }
}

/// The product of parsing a PDF for playback: a playable `Score`, the geometry linking it back to the
/// original PDF, and any diagnostics the importer emitted.
public struct PDFPlaybackParseResult: Sendable {
    public let score: Score
    public let geometry: any PDFPlaybackGeometry
    public let diagnostics: [PDFParseDiagnostic]

    public init(
        score: Score,
        geometry: any PDFPlaybackGeometry,
        diagnostics: [PDFParseDiagnostic],
    ) {
        self.score = score
        self.geometry = geometry
        self.diagnostics = diagnostics
    }
}

/// Parses an imported PDF into a playable score plus on-PDF geometry. Implemented in Infrastructure
/// over swift-sheet-music's PDF importer (Apple-only) and injected into the Reader as an optional
/// dependency, so platforms / builds without the importer simply omit it and the PDF reader stays
/// display-only.
public protocol PDFPlaybackParser: Sendable {
    /// Parse the PDF at `pdfURL`. Throws if the file can't be read or yields nothing playable. Runs
    /// off the main actor — OMR is heavy.
    func parse(pdfURL: URL) async throws -> PDFPlaybackParseResult
}
