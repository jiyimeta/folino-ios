import CryptoKit
import Domain
import Foundation

public final class LiveScoreFileImporter: ScoreFileImporter, Sendable {
    private let gateway: any ScoreFileGateway
    // `ScoreLibraryRepository` is `@MainActor`-isolated, which guarantees
    // single-actor access. Swift 6's type system doesn't (yet) infer Sendable
    // from the actor annotation alone, so we assert it here.
    private nonisolated(unsafe) let repository: any ScoreLibraryRepository
    private let scoresDirectory: URL

    public init(
        gateway: any ScoreFileGateway,
        repository: any ScoreLibraryRepository,
        scoresDirectory: URL
    ) {
        self.gateway = gateway
        self.repository = repository
        self.scoresDirectory = scoresDirectory
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

        return ImportPlan(
            sourceURL: sourceURL,
            format: format,
            summary: summary,
            contentHash: hash,
            sizeBytes: size,
            duplicates: duplicates
        )
    }

    public func commitImport(_ plan: ImportPlan, decision: ImportDecision) async throws -> ScoreItem {
        switch decision {
        case let .openExisting(existingID):
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

        case .importAsNew:
            let id = ScoreItemID()
            let localFileName = "\(id.rawValue.uuidString).\(plan.format.canonicalExtension)"
            let destinationURL = scoresDirectory.appending(path: localFileName)

            // Copy first, with scoped access for share-sheet URLs.
            let scoped = plan.sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { plan.sourceURL.stopAccessingSecurityScopedResource() } }

            do {
                try FileManager.default.copyItem(at: plan.sourceURL, to: destinationURL)
            } catch {
                throw DomainError.persistenceFailed(reason: "copy failed: \(error)")
            }

            // Best-effort cleanup if the row save fails. We re-throw the original error.
            var copiedFileShouldBeRemoved = true
            defer {
                if copiedFileShouldBeRemoved {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
            }

            let item = ScoreItem(
                id: id,
                title: plan.summary.title ?? plan.sourceURL.deletingPathExtension().lastPathComponent,
                composer: plan.summary.composer,
                instrumentationSummary: plan.summary.instrumentationSummary,
                localFileName: localFileName,
                contentHash: plan.contentHash,
                sizeBytes: plan.sizeBytes,
                lengthBeats: plan.summary.lengthBeats,
                defaultTempoBpm: plan.summary.defaultTempoBpm,
                primaryKey: plan.summary.primaryKey,
                addedAt: Date(),
                lastOpenedAt: nil,
                tagIDs: [],
                isFavorite: false
            )

            try await repository.saveScoreItem(item)
            copiedFileShouldBeRemoved = false
            return item
        }
    }

    /// SHA-256 the file in a single pass. Off-main via `Task.detached` so
    /// large MSCZ archives don't stall the main actor.
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
