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
        gateway: any ScoreFileGateway
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

    public func availableFormats(for item: ScoreItem) -> [ScoreShareFormat] {
        // localFileName follows the import-time invariant
        // "<id>.<canonical-extension>", so detect() is total here.
        switch ScoreFormat.detect(filename: item.localFileName) {
        case .mscx?, .mscz?:
            return [.msczOriginal, .pdf, .midi]
        default:
            // TODO: re-evaluate when LiveScoreFileGateway gains MIDI parsing —
            // PDF/MIDI/MSCZ for a `.midi` item would fail with `scoreParseFailed`
            // until then. Imports of `.midi` are currently blocked.
            return [.msczMuseScore4, .msczMuseScore3, .pdf, .midi]
        }
    }

    public func prepareShare(
        item: ScoreItem,
        format: ScoreShareFormat
    ) async throws -> URL {
        let title = Self.sanitize(title: item.title)
        switch format {
        case .msczOriginal:
            return try prepareMSCZOriginal(item: item, sanitizedTitle: title)
        case .msczMuseScore4:
            return try await prepareMSCZExport(
                item: item, sanitizedTitle: title, target: .v4
            )
        case .msczMuseScore3:
            return try await prepareMSCZExport(
                item: item, sanitizedTitle: title, target: .v3
            )
        case .pdf:
            return try await preparePDF(item: item, sanitizedTitle: title)
        case .midi:
            return try await prepareMIDI(item: item, sanitizedTitle: title)
        }
    }

    private func prepareMIDI(
        item: ScoreItem,
        sanitizedTitle: String
    ) async throws -> URL {
        let sourceURL = scoresDirectory.appending(path: item.localFileName)
        let (score, _) = try await gateway.loadScore(fileURL: sourceURL)
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

    private func preparePDF(
        item: ScoreItem,
        sanitizedTitle: String
    ) async throws -> URL {
        let sourceURL = scoresDirectory.appending(path: item.localFileName)
        let (score, _) = try await gateway.loadScore(fileURL: sourceURL)
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

    private func prepareMSCZOriginal(
        item: ScoreItem,
        sanitizedTitle: String
    ) throws -> URL {
        let sourceURL = scoresDirectory.appending(path: item.localFileName)
        let destination = shareTempDirectory.appending(path: "\(sanitizedTitle).mscz")
        try? FileManager.default.removeItem(at: destination)

        guard let onDisk = ScoreFormat.detect(filename: item.localFileName) else {
            throw DomainError.unsupportedFormat(sourceURL.pathExtension)
        }
        switch onDisk {
        case .mscx:
            let mscxData: Data
            do {
                mscxData = try Data(contentsOf: sourceURL)
            } catch {
                throw DomainError.scoreFileNotFound(name: item.localFileName)
            }
            let msczData: Data
            do {
                msczData = try MSCZWriter.write(mscxData: mscxData)
            } catch {
                throw DomainError.scoreWriteFailed(reason: "\(error)")
            }
            do {
                try msczData.write(to: destination)
            } catch {
                throw DomainError.scoreWriteFailed(reason: "\(error)")
            }
            return destination
        case .mscz:
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            } catch {
                throw DomainError.scoreFileNotFound(name: item.localFileName)
            }
            return destination
        case .musicXML, .mxl, .midi:
            // Caller error: `availableFormats(for:)` only offers
            // `.msczOriginal` to items whose source is `.mscx`/`.mscz`.
            throw DomainError.unsupportedFormat(sourceURL.pathExtension)
        }
    }

    private func prepareMSCZExport(
        item: ScoreItem,
        sanitizedTitle: String,
        target: MSCXVersion
    ) async throws -> URL {
        let sourceURL = scoresDirectory.appending(path: item.localFileName)
        let destination = shareTempDirectory.appending(path: "\(sanitizedTitle).mscz")
        try? FileManager.default.removeItem(at: destination)

        let (score, _) = try await gateway.loadScore(fileURL: sourceURL)
        do {
            try MSCZWriter.write(
                score: score,
                options: MSCXEncoderOptions(targetVersion: target),
                to: destination
            )
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
        return destination
    }
}
