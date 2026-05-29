import Domain
import Foundation
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
        let (_, summary) = try await loadScore(fileURL: fileURL)
        // Right now the summary is built from the parsed Score regardless; when swift-sheet-music exposes a
        // metadata-only fast path we'll bypass full parsing. Stays correct under that future change.
        return summary
    }

    public func loadScore(fileURL: URL) async throws -> (score: Score, summary: ScoreFileSummary) {
        guard let format = detectFormat(fileName: fileURL.lastPathComponent) else {
            let ext = fileURL.pathExtension.lowercased()
            throw DomainError.unsupportedFormat(ext)
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

    public func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) throws {
        // v1: swift-sheet-music has no Score → MSCX/MSCZ/MusicXML serializer. The Editor plan will fill this in.
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }

    /// Bridges a swift-sheet-music MSCX/MSCZ parse result into the gateway's `(Score, [ScoreParseDiagnostic])` shape.
    private static func result(from parsed: MSCXParseResult) -> (Score, [ScoreParseDiagnostic]) {
        (parsed.score, parsed.diagnostics.map(ScoreParseDiagnostic.init))
    }
}
