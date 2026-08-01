import CryptoKit
import Domain
import Foundation

public final class LiveScoreFileImporter: ScoreFileImporter, Sendable {
    private let gateway: any ScoreFileGateway
    // `ScoreLibraryRepository` is `@MainActor`-isolated, which guarantees single-actor access. Swift 6's type system
    // doesn't (yet) infer Sendable from the actor annotation alone, so we assert it here.
    private nonisolated(unsafe) let repository: any ScoreLibraryRepository
    private let scoresDirectory: URL
    /// Reads an imported PDF into notation. `nil` on builds without swift-sheet-music's PDF importer, where a PDF
    /// imports exactly as it did before folino could read one.
    private let pdfConversion: PDFScoreConversion?

    public init(
        gateway: any ScoreFileGateway,
        repository: any ScoreLibraryRepository,
        scoresDirectory: URL,
        pdfConversion: PDFScoreConversion? = nil,
    ) {
        self.gateway = gateway
        self.repository = repository
        self.scoresDirectory = scoresDirectory
        self.pdfConversion = pdfConversion
    }

    public func prepareImport(sourceURL: URL) async throws -> ImportPlan {
        guard let format = gateway.detectFormat(fileName: sourceURL.lastPathComponent) else {
            throw DomainError.unsupportedFormat(sourceURL.pathExtension.lowercased())
        }

        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let (hash, size) = try await Self.hashAndSize(sourceURL)

        let summary = try await gateway.loadFileMetadata(fileURL: sourceURL)
        let duplicates = try await repository.scoreItems(matchingContentHash: hash)

        // Copy the bytes into our own sandbox while the source's security scope is still open. URLs delivered via
        // `.onOpenURL` are one-shot: releasing scope here and re-acquiring it later in `commitImport` does not grant
        // access on a real device. Staging decouples the commit step from scope entirely.
        //
        // We stage inside a `.staging` subdirectory of the managed scores directory (rather than
        // `URL.temporaryDirectory`). That keeps staging files co-located with the destination — `moveItem` is a fast
        // intra-directory rename — and ensures abandoned staged files are cleaned up when the user uninstalls the app.
        let stagingDir = scoresDirectory.appending(path: ".staging", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedURL = stagingDir.appending(
            path: "\(UUID().uuidString).\(format.canonicalExtension)",
        )
        do {
            try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
        } catch {
            throw DomainError.persistenceFailed(reason: "stage copy failed: \(error)")
        }

        return ImportPlan(
            sourceURL: sourceURL,
            stagedURL: stagedURL,
            format: format,
            summary: summary,
            contentHash: hash,
            sizeBytes: size,
            duplicates: duplicates,
        )
    }

    public func commitImport(_ plan: ImportPlan, decision: ImportDecision) async throws -> ScoreItem {
        switch decision {
        case let .openExisting(existingID):
            try await openExisting(plan, existingID: existingID)
        case .importAsNew:
            try await importAsNew(plan)
        }
    }

    private func openExisting(_ plan: ImportPlan, existingID: ScoreItemID) async throws -> ScoreItem {
        // The existing item already lives in scoresDirectory; staged copy is unused.
        try? FileManager.default.removeItem(at: plan.stagedURL)

        if let existing = plan.duplicates.first(where: { $0.id == existingID }) {
            return existing
        }
        // Fall back to a repository lookup if the duplicates list was stale.
        if let item = try await repository.scoreItems(matchingContentHash: plan.contentHash)
            .first(where: { $0.id == existingID })
        {
            return item
        }
        throw DomainError.persistenceFailed(reason: "openExisting target \(existingID.rawValue) not found")
    }

    private func importAsNew(_ plan: ImportPlan) async throws -> ScoreItem {
        let id = ScoreItemID()
        let importedFileName = "\(id.rawValue.uuidString).\(plan.format.canonicalExtension)"
        let destinationURL = scoresDirectory.appending(path: importedFileName)

        // Move the staged copy into the managed location. No security scope needed — staging lives in our own tmp
        // directory.
        do {
            try FileManager.default.moveItem(at: plan.stagedURL, to: destinationURL)
        } catch {
            throw DomainError.persistenceFailed(reason: "move failed: \(error)")
        }

        let file = await committedFile(for: plan, id: id, importedFileName: importedFileName, at: destinationURL)

        // Best-effort cleanup if the row save fails. We re-throw the original error. Both files go — leaving the
        // converted score behind would orphan it with no row pointing at it.
        var copiedFileShouldBeRemoved = true
        defer {
            if copiedFileShouldBeRemoved {
                try? FileManager.default.removeItem(at: destinationURL)
                if let url = file.convertedScoreURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        // Every format — PDF included — takes its title from the source file name. PDFs do carry a `/Title`
        // document attribute (the gateway surfaces it in `summary.title`), but exporters bake their own internal
        // project name into it: a MuseScore export of a file the user filed away as `spring-song.pdf` arrives with
        // `/Title = "アイデア#0131"`. The file name is what the user chose, so it wins; renaming stays a separate
        // user action. Reading a PDF into notation doesn't change that — the parsed title is no more the user's than
        // the PDF's was.
        let summary = file.summary
        let item = ScoreItem(
            id: id,
            title: ScorePresentation.title(fromFilename: plan.sourceURL.lastPathComponent),
            subtitle: summary.subtitle,
            composer: summary.composer,
            arranger: summary.arranger,
            lyricist: summary.lyricist,
            copyright: summary.copyright,
            instrumentationSummary: summary.instrumentationSummary,
            localFileName: file.localFileName,
            contentHash: file.contentHash,
            sizeBytes: file.sizeBytes,
            lengthBeats: summary.lengthBeats,
            defaultTempoBpm: summary.defaultTempoBpm,
            primaryKey: summary.primaryKey,
            addedAt: Date(),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
            museScoreMajorVersion: summary.museScoreMajorVersion,
            sourcePDFFileName: file.sourcePDFFileName,
            sourcePDFContentHash: file.sourcePDFContentHash,
            pdfDerivedContentHash: file.pdfDerivedContentHash,
            pdfConversionFailed: file.pdfConversionFailed,
        )

        try await repository.saveScoreItem(item)
        copiedFileShouldBeRemoved = false
        return item
    }

    /// What will actually back the new row. For every format but PDF this is just the imported file; a PDF is read
    /// into notation here, so the row that lands in the library is a normal score row — correct length, tempo, parts,
    /// thumbnail, and an editable file — with the original kept beside it for the Reader's original-PDF view and the
    /// re-read action. A PDF folino can't read stays a PDF item, exactly as before.
    private struct CommittedFile {
        var localFileName: String
        var contentHash: String
        var sizeBytes: Int64
        var summary: ScoreFileSummary
        var sourcePDFFileName: String?
        var sourcePDFContentHash: String?
        var pdfDerivedContentHash: String?
        var pdfConversionFailed = false
        /// Set only when a conversion wrote one, so the failure path can clean it up.
        var convertedScoreURL: URL?
    }

    private func committedFile(
        for plan: ImportPlan,
        id: ScoreItemID,
        importedFileName: String,
        at destinationURL: URL,
    ) async -> CommittedFile {
        var file = CommittedFile(
            localFileName: importedFileName,
            contentHash: plan.contentHash,
            sizeBytes: plan.sizeBytes,
            summary: plan.summary,
        )
        guard plan.format == .pdf else { return file }

        file.sourcePDFFileName = importedFileName
        file.sourcePDFContentHash = plan.contentHash
        let msczName = "\(id.rawValue.uuidString).\(ScoreFormat.mscz.canonicalExtension)"
        let msczURL = scoresDirectory.appending(path: msczName)
        guard let facts = await pdfConversion?(destinationURL, msczURL) else {
            file.pdfConversionFailed = true
            return file
        }
        file.localFileName = facts.fileName
        file.contentHash = facts.contentHash
        file.sizeBytes = facts.sizeBytes
        file.summary = facts.summary
        file.pdfDerivedContentHash = facts.contentHash
        file.convertedScoreURL = msczURL
        return file
    }

    /// SHA-256 the file in a single pass. Off-main via `Task.detached` so large MSCZ archives don't stall the main
    /// actor.
    private static func hashAndSize(_ url: URL) async throws -> (String, Int64) {
        try await Task.detached(priority: .utility) {
            do {
                var hasher = SHA256()
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let chunkSize = 64 * 1024
                var total: Int64 = 0
                while true {
                    let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                    total += Int64(chunk.count)
                }
                let digest = hasher.finalize()
                let hex = digest.map { String(format: "%02x", $0) }.joined()
                return (hex, total)
            } catch {
                throw DomainError.scoreFileNotFound(name: url.lastPathComponent)
            }
        }.value
    }
}
