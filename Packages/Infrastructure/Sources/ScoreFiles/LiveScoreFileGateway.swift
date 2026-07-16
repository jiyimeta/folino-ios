import Domain
import Foundation
import PDFKit
import SheetMusic
import UtilityCore

/// Live `ScoreFileGateway` backed by `swift-sheet-music`. Per-format dispatch happens in this single file so the
/// surface stays small.
public struct LiveScoreFileGateway: ScoreFileGateway {
    private let crashReporter: any CrashReporter

    public init(crashReporter: any CrashReporter = NoopCrashReporter()) {
        self.crashReporter = crashReporter
    }

    public func detectFormat(fileName: String) -> ScoreFormat? {
        ScoreFormat.detect(filename: fileName)
    }

    public func loadFileMetadata(fileURL: URL) async throws -> ScoreFileSummary {
        if detectFormat(fileName: fileURL.lastPathComponent) == .pdf {
            return try Self.pdfSummary(fileURL: fileURL)
        }
        let (_, summary) = try await loadScore(fileURL: fileURL)
        // Right now the summary is built from the parsed Score regardless; when swift-sheet-music exposes a
        // metadata-only fast path we'll bypass full parsing. Stays correct under that future change.
        return summary
    }

    /// Builds a metadata-only summary for a PDF without parsing any notation. `/Title` becomes the title when present;
    /// musical fields are zeroed because a PDF carries no notation. Page count is intentionally not stored — the reader
    /// reads it from the document at open time.
    static func pdfSummary(fileURL: URL) throws -> ScoreFileSummary {
        guard let doc = PDFDocument(url: fileURL), doc.pageCount > 0 else {
            throw DomainError.scoreParseFailed(reason: "Unreadable or empty PDF")
        }
        let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return ScoreFileSummary(
            title: title,
            composer: nil,
            instrumentationSummary: "",
            lengthBeats: 0,
            defaultTempoBpm: 0,
            primaryKey: nil,
        )
    }

    public func loadScore(fileURL: URL) async throws -> (score: Score, summary: ScoreFileSummary) {
        guard let format = detectFormat(fileName: fileURL.lastPathComponent) else {
            let ext = fileURL.pathExtension.lowercased()
            throw DomainError.unsupportedFormat(ext)
        }
        // PDFs are fixed-layout documents, never parsed into a `Score`. Reject here so the detached parse switch below
        // stays exhaustive over the reachable (parseable) formats.
        if format == .pdf {
            throw DomainError.unsupportedFormat("pdf")
        }
        let crashReporter = crashReporter
        return try await Task.detached(priority: .userInitiated) {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw DomainError.scoreFileNotFound(name: fileURL.lastPathComponent)
            }
            do {
                let (score, diagnostics): (Score, [ScoreParseDiagnostic]) = switch format {
                case .mscx:
                    try Self.result(from: MSCXParser.parseWithDiagnostics(data))
                case .mscz:
                    try Self.result(from: MSCZReader.parseWithDiagnostics(data))
                case .musicXML:
                    try (SheetMusic.loadScore(musicXMLData: data), [])
                case .mxl:
                    try (SheetMusic.loadScore(mxlData: data), [])
                case .midi:
                    try (SheetMusic.loadScore(
                        midiData: data,
                        sourceFilename: fileURL.deletingPathExtension().lastPathComponent,
                    ), [])
                case .pdf:
                    // Unreachable: PDF is rejected before this closure runs. Present only to keep the switch
                    // exhaustive over `ScoreFormat`.
                    throw DomainError.unsupportedFormat("pdf")
                }
                ScoreDiagnosticReporter(crashReporter: crashReporter).report(diagnostics)
                return (score, ScoreFileSummary(score: score))
            } catch let error as DomainError {
                throw error
            } catch {
                throw DomainError.scoreParseFailed(reason: "\(error)")
            }
        }.value
    }

    public func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) async throws {
        // `.mscx`/`.mscz` route through the engine's encoders. Other formats have no Score → bytes encoder yet; the
        // Editor decides where such sources land on save (e.g. a sibling `.mscz`) rather than this gateway guessing.
        switch format {
        case .mscx, .mscz:
            try await Task.detached(priority: .userInitiated) {
                do {
                    if format == .mscx {
                        try SheetMusic.exportMSCX(score, to: fileURL)
                    } else {
                        try SheetMusic.exportMSCZ(score, to: fileURL)
                    }
                } catch {
                    throw DomainError.scoreWriteFailed(reason: "\(error)")
                }
            }.value
        case .musicXML, .mxl, .midi, .pdf:
            // No upstream encoder for these formats. The Editor saves such sources as a sibling `.mscz` instead
            // (format policy lives in the Editor feature, not here).
            throw DomainError.unsupportedFormat(format.canonicalExtension)
        }
    }

    /// Bridges a swift-sheet-music MSCX/MSCZ parse result into the gateway's `(Score, [ScoreParseDiagnostic])` shape.
    private static func result(from parsed: MSCXParseResult) -> (Score, [ScoreParseDiagnostic]) {
        (parsed.score, parsed.diagnostics.map(ScoreParseDiagnostic.init))
    }
}
