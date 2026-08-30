import Domain
import Foundation
import SheetMusic
import SheetMusicMSCX

/// Live `ScoreShareService` backed by `swift-sheet-music`. Companion to `LiveScoreFileGateway` in the same module.
public struct LiveScoreShareService: ScoreShareService {
    private let scoresDirectory: URL
    private let shareTempDirectory: URL
    private let gateway: any ScoreFileGateway
    private let audioExporter: any ScoreAudioExporter
    private let pdfRenderer: any ScorePDFRenderer

    public init(
        scoresDirectory: URL,
        shareTempDirectory: URL,
        gateway: any ScoreFileGateway,
        audioExporter: any ScoreAudioExporter,
        pdfRenderer: any ScorePDFRenderer,
    ) {
        self.scoresDirectory = scoresDirectory
        self.shareTempDirectory = shareTempDirectory
        self.gateway = gateway
        self.audioExporter = audioExporter
        self.pdfRenderer = pdfRenderer
    }

    public func availableFormats(for item: ScoreItem) async -> [ScoreShareFormatOption] {
        let formats = ScoreShareFormat.allOrdered
        let original = await detectOriginalFormat(for: item)
        return formats.map { ScoreShareFormatOption(format: $0, isOriginal: $0 == original) }
    }

    public func prepareShare(
        item: ScoreItem,
        format: ScoreShareFormat,
    ) async throws -> URL {
        let title = ScoreExportNaming.sanitize(title: item.title)
        let sourceURL = scoresDirectory.appending(path: item.localFileName)
        let (score, _) = try await gateway.loadScore(fileURL: sourceURL)

        if ScoreShareFormat.matching(for: score.source) == format {
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
            return try await writeM4A(score: score, sanitizedTitle: title)
        case .annotatedPDF, .annotatedOriginalPDF:
            // Task 7 replaces this with the real routing; the rows are not offered yet, so this is unreachable.
            throw DomainError.scoreWriteFailed(reason: "annotated export is not wired up yet")
        }
    }

    // MARK: - Source-based mapping

    /// Loads the item via the gateway just to read `Score.source` and map it to the matching share format. Errors map
    /// to `nil` so a transient parse failure simply leaves the menu unflagged instead of breaking it.
    private func detectOriginalFormat(for item: ScoreItem) async -> ScoreShareFormat? {
        let url = scoresDirectory.appending(path: item.localFileName)
        guard let result = try? await gateway.loadScore(fileURL: url) else { return nil }
        return ScoreShareFormat.matching(for: result.0.source)
    }

    // MARK: - Original-bytes copy

    /// Copy the source file as-is into the share temp directory, preserving its extension. Used when the picked format
    /// matches the item's source byte-for-byte.
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
        let pdfData = try await pdfRenderer.renderPDF(score: score, title: item.title)
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

    private func writeM4A(
        score: Score,
        sanitizedTitle: String,
    ) async throws -> URL {
        let destination = shareTempDirectory.appending(path: "\(sanitizedTitle).m4a")
        try? FileManager.default.removeItem(at: destination)
        try await audioExporter.exportM4A(score: score, to: destination)
        return destination
    }
}
