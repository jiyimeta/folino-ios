import Domain
import Foundation
import SheetMusic
import SheetMusicMSCX
import SheetMusicPDF

/// Live `ScoreShareService` backed by `swift-sheet-music`. Companion to
/// `LiveScoreFileGateway` in the same module.
public struct LiveScoreShareService: ScoreShareService {
    private let scoresDirectory: URL
    private let shareTempDirectory: URL
    private let gateway: any ScoreFileGateway

    public init(
        scoresDirectory: URL,
        shareTempDirectory: URL,
        gateway: any ScoreFileGateway,
    ) {
        self.scoresDirectory = scoresDirectory
        self.shareTempDirectory = shareTempDirectory
        self.gateway = gateway
    }

    /// Internal for tests. Replaces filesystem-hostile characters,
    /// trims to ≤100 chars, falls back to `"score"` if empty.
    static func sanitize(title: String) -> String {
        let bad: Set<Character> = ["/", ":", "\\", "\u{0000}"]
        let cleaned = String(title.map { bad.contains($0) ? "_" : $0 })
        let stripped = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_ "))
        let candidate = stripped.isEmpty ? "score" : stripped
        return String(candidate.prefix(100))
    }

    public func availableFormats(for item: ScoreItem) async -> [ScoreShareFormatOption] {
        let formats: [ScoreShareFormat] = [.museScoreV4, .museScoreV3, .pdf, .midi]
        let original = await detectOriginalFormat(for: item)
        return formats.map { ScoreShareFormatOption(format: $0, isOriginal: $0 == original) }
    }

    public func prepareShare(
        item: ScoreItem,
        format: ScoreShareFormat,
    ) async throws -> URL {
        let title = Self.sanitize(title: item.title)
        let sourceURL = scoresDirectory.appending(path: item.localFileName)
        let (score, _) = try await gateway.loadScore(fileURL: sourceURL)

        if Self.matchingFormat(for: score.source) == format {
            return try copyOriginalBytes(sourceURL: sourceURL, sanitizedTitle: title)
        }

        switch format {
        case .museScoreV4:
            return try writeMSCZ(score: score, sanitizedTitle: title, target: .v4)
        case .museScoreV3:
            return try writeMSCZ(score: score, sanitizedTitle: title, target: .v3)
        case .pdf:
            return try await writePDF(score: score, item: item, sanitizedTitle: title)
        case .midi:
            return try writeMIDI(score: score, sanitizedTitle: title)
        case .audioM4A:
            throw DomainError.unsupportedFormat("audioM4A")
        }
    }

    // MARK: - Source-based mapping

    /// `ScoreSource` → matching `ScoreShareFormat`. Returns `nil` for
    /// sources we don't expose as shareable formats today (MusicXML,
    /// PDF, MuseScore 2, unknown).
    static func matchingFormat(for source: ScoreSource) -> ScoreShareFormat? {
        switch source {
        case .midi: .midi
        case .museScore(.v4): .museScoreV4
        case .museScore(.v3): .museScoreV3
        case .museScore(.v2), .musicXML, .pdf, .unknown: nil
        }
    }

    /// Loads the item via the gateway just to read `Score.source` and
    /// map it to the matching share format. Errors map to `nil` so a
    /// transient parse failure simply leaves the menu unflagged
    /// instead of breaking it.
    private func detectOriginalFormat(for item: ScoreItem) async -> ScoreShareFormat? {
        let url = scoresDirectory.appending(path: item.localFileName)
        guard let result = try? await gateway.loadScore(fileURL: url) else { return nil }
        return Self.matchingFormat(for: result.0.source)
    }

    // MARK: - Original-bytes copy

    /// Copy the source file as-is into the share temp directory,
    /// preserving its extension. Used when the picked format matches
    /// the item's source byte-for-byte.
    private func copyOriginalBytes(
        sourceURL: URL,
        sanitizedTitle: String,
    ) throws -> URL {
        let ext = sourceURL.pathExtension
        let destination = shareTempDirectory.appending(path: "\(sanitizedTitle).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            throw DomainError.scoreFileNotFound(name: sourceURL.lastPathComponent)
        }
        return destination
    }

    // MARK: - Encoder paths

    private func writeMIDI(
        score: Score,
        sanitizedTitle: String,
    ) throws -> URL {
        let midiData: Data
        do {
            midiData = try SheetMusic.exportMIDI(score: score)
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
        let destination = shareTempDirectory.appending(path: "\(sanitizedTitle).mid")
        try? FileManager.default.removeItem(at: destination)
        do {
            try midiData.write(to: destination)
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
        return destination
    }

    private func writePDF(
        score: Score,
        item: ScoreItem,
        sanitizedTitle: String,
    ) async throws -> URL {
        let pdfData = try await MainActor.run {
            try PDFExporter.export(score: score, options: PDFExporter.Options(title: item.title))
        }
        let destination = shareTempDirectory.appending(path: "\(sanitizedTitle).pdf")
        try? FileManager.default.removeItem(at: destination)
        do {
            try pdfData.write(to: destination)
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
        return destination
    }

    private func writeMSCZ(
        score: Score,
        sanitizedTitle: String,
        target: MSCXVersion,
    ) throws -> URL {
        let destination = shareTempDirectory.appending(path: "\(sanitizedTitle).mscz")
        try? FileManager.default.removeItem(at: destination)
        do {
            try MSCZWriter.write(
                score: score,
                options: MSCXEncoderOptions(targetVersion: target),
                to: destination,
            )
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
        return destination
    }
}
