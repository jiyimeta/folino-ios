import CryptoKit
import Domain
import Foundation

/// File-side half of `ScoreOriginalStore`. Every decision it makes comes from `OriginalCapture` / `RevertPolicy` in
/// Domain; this type only moves bytes and rebuilds the row.
public struct LiveScoreOriginalStore: ScoreOriginalStore {
    private let scoresDirectory: URL
    private let gateway: any ScoreFileGateway

    public init(scoresDirectory: URL, gateway: any ScoreFileGateway) {
        self.scoresDirectory = scoresDirectory
        self.gateway = gateway
    }

    /// Runs entirely off the caller's actor: `copyItem`/`moveItem`/the whole-file SHA-256 in `hashAndSize` are
    /// synchronous and can be non-trivial (a large score's bytes), and the first caller (`EditorViewModel.
    /// performSave()`) is `@MainActor`. Same shape as `LiveScoreFileGateway.loadScore` / `saveScore`.
    public func captureOriginalIfNeeded(for item: ScoreItem) async throws -> ScoreItem {
        let scoresDirectory = scoresDirectory
        return await Task.detached(priority: .userInitiated) {
            let plan = OriginalCapture.plan(
                for: item,
                adoptableSourceFileName: Self.adoptableSourceFileName(for: item, in: scoresDirectory),
            )
            switch plan {
            case .none:
                return item
            case let .adopt(fileName, provenance):
                guard let facts = try? Self.hashAndSize(of: scoresDirectory.appending(path: fileName)) else {
                    return item
                }
                return item.capturingOriginal(
                    fileName: fileName,
                    contentHash: facts.contentHash,
                    provenance: provenance,
                )
            case let .copy(sidecarFileName, provenance):
                let source = scoresDirectory.appending(path: item.localFileName)
                let destination = scoresDirectory.appending(path: sidecarFileName)
                // The sidecar's existence is the marker, so re-check it here rather than trusting the row: a
                // capture whose row update was lost must find the file and adopt it, not copy the edited bytes
                // over it.
                if !FileManager.default.fileExists(atPath: destination.path) {
                    guard (try? Self.copyAtomically(from: source, to: destination)) != nil else { return item }
                }
                guard let facts = try? Self.hashAndSize(of: destination) else { return item }
                return item.capturingOriginal(
                    fileName: sidecarFileName,
                    contentHash: facts.contentHash,
                    provenance: provenance,
                )
            }
        }.value
    }

    public func adoptOrphanedOriginal(for item: ScoreItem) async -> ScoreItem {
        let scoresDirectory = scoresDirectory
        return await Task.detached(priority: .userInitiated) {
            let plan = OriginalCapture.plan(
                for: item,
                adoptableSourceFileName: Self.adoptableSourceFileName(for: item, in: scoresDirectory),
            )
            let fileName: String
            let provenance: OriginalProvenance
            switch plan {
            case .none:
                // Already recorded, or a file the editor could never overwrite. Either way, nothing orphaned.
                return item
            case let .adopt(name, adoptedProvenance):
                fileName = name
                provenance = adoptedProvenance
            case let .copy(sidecarFileName, copyProvenance):
                // The one difference from `captureOriginalIfNeeded`: it would copy here. This only registers a
                // sidecar that a previous session already wrote, so a score that has never been edited is left
                // exactly as it was.
                fileName = sidecarFileName
                provenance = copyProvenance
            }
            let url = scoresDirectory.appending(path: fileName)
            guard FileManager.default.fileExists(atPath: url.path),
                  let facts = try? Self.hashAndSize(of: url)
            else { return item }
            return item.capturingOriginal(
                fileName: fileName,
                contentHash: facts.contentHash,
                provenance: provenance,
            )
        }.value
    }

    /// The first candidate that is actually on disk — an untouched import file left beside an edited `.mscz`.
    private static func adoptableSourceFileName(for item: ScoreItem, in scoresDirectory: URL) -> String? {
        item.adoptableSourceFileNames.first {
            FileManager.default.fileExists(atPath: scoresDirectory.appending(path: $0).path)
        }
    }

    /// Copies through a scratch name and renames, so a kill mid-copy cannot leave a truncated file sitting at the
    /// sidecar's path — where the existence check would then trust it.
    private static func copyAtomically(from source: URL, to destination: URL) throws {
        let scratch = destination.deletingLastPathComponent()
            .appending(path: "\(destination.lastPathComponent).capturing")
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.copyItem(at: source, to: scratch)
        try FileManager.default.moveItem(at: scratch, to: destination)
    }

    /// SHA-256 + size, in the importer's hex-digest format. Same shape as `EditorFileFacts.hashAndSize`, which stays
    /// where it is: the Editor cannot import Infrastructure.
    static func hashAndSize(of url: URL) throws -> (contentHash: String, sizeBytes: Int64) {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var total: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    /// Writes the original back and rebuilds the row from it.
    ///
    /// File first, row second, on purpose. A kill between them leaves the file restored and the row's hash stale —
    /// the user opens their original and loses nothing, and the next save or revert corrects the hash. The other
    /// order would leave a row claiming the original over a file that still held the edits, which is worse.
    ///
    /// The file swap, hash, and hash check run off the caller's actor via `Task.detached` — same reasoning as
    /// `captureOriginalIfNeeded`: a whole-file copy plus a SHA-256 is comparable, non-trivial work, and the
    /// callers named on `ScoreOriginalStore` (the Reader, the score-info sheet) are `@MainActor`. `restoreFile` is
    /// `static` so `self` never crosses the boundary. `gateway.loadFileMetadata` is called back on the caller's
    /// actor afterward rather than from inside the detached closure — not because `gateway` couldn't safely cross
    /// (`ScoreFileGateway: Sendable`, so it could), but because it is already its own suspension point and it is
    /// the one piece of this method that parses rather than just moving bytes; keeping the detached closure to
    /// plain file I/O keeps its shape identical to `captureOriginalIfNeeded`'s.
    public func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) async throws -> ScoreItem {
        let scoresDirectory = scoresDirectory
        let restoredFacts = try await Task.detached(priority: .userInitiated) {
            try Self.restoreFile(for: item, in: scoresDirectory)
        }.value

        let restored = scoresDirectory.appending(path: restoredFacts.localFileName)
        let summary = try await gateway.loadFileMetadata(fileURL: restored)
        return item.adoptingRevertedOriginal(
            RevertedOriginalFacts(
                localFileName: restoredFacts.localFileName,
                contentHash: restoredFacts.contentHash,
                sizeBytes: restoredFacts.sizeBytes,
                summary: summary,
            ),
            restoringScoreInfo: restoringScoreInfo,
        )
    }

    /// Performs the file plan from `RevertPolicy.filePlan(for:)` and returns the restored file's identity and hash.
    /// Static so it never captures `self` crossing the `Task.detached` boundary in `revertToOriginal`.
    ///
    /// Verifies the source's hash — the sidecar, or the adopt-target — before touching anything. The whole promise
    /// of this feature is that the bytes coming back are the bytes that went in, so a corrupted original must be
    /// refused with the edit and its only backup both still intact, not discovered only after they are gone: the
    /// copy or adoption that follows is byte-for-byte, so hashing the source proves exactly what hashing the
    /// result would have proven.
    private static func restoreFile(
        for item: ScoreItem,
        in scoresDirectory: URL,
    ) throws -> (localFileName: String, contentHash: String, sizeBytes: Int64) {
        guard let plan = RevertPolicy.filePlan(for: item) else {
            throw DomainError.scoreWriteFailed(reason: "no original recorded for \(item.localFileName)")
        }
        switch plan {
        case let .restoreSidecar(sidecarFileName, over):
            let sidecar = scoresDirectory.appending(path: sidecarFileName)
            guard FileManager.default.fileExists(atPath: sidecar.path) else {
                throw DomainError.scoreFileNotFound(name: sidecarFileName)
            }
            let facts = try verifiedHashAndSize(of: sidecar, against: item.originalContentHash, name: sidecarFileName)
            try swapIn(sidecar, over: scoresDirectory.appending(path: over))
            try? FileManager.default.removeItem(at: sidecar)
            return (over, facts.contentHash, facts.sizeBytes)
        case let .adoptExistingFile(originalFileName, deleting):
            let source = scoresDirectory.appending(path: originalFileName)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw DomainError.scoreFileNotFound(name: originalFileName)
            }
            let facts = try verifiedHashAndSize(of: source, against: item.originalContentHash, name: originalFileName)
            try? FileManager.default.removeItem(at: scoresDirectory.appending(path: deleting))
            return (originalFileName, facts.contentHash, facts.sizeBytes)
        }
    }

    /// Hashes `url` and, when `expectedHash` is non-`nil`, throws before returning if it disagrees — the check the
    /// caller must run before mutating anything.
    private static func verifiedHashAndSize(
        of url: URL,
        against expectedHash: String?,
        name: String,
    ) throws -> (contentHash: String, sizeBytes: Int64) {
        let facts = try hashAndSize(of: url)
        if let expected = expectedHash, expected != facts.contentHash {
            throw DomainError.scoreWriteFailed(reason: "restored original does not match its recorded hash (\(name))")
        }
        return facts
    }

    /// Copies `source` over `destination` through a scratch file, so a failure part-way cannot leave the score
    /// truncated. `replaceItemAt` needs the scratch to be a real file it can move into place.
    private static func swapIn(_ source: URL, over destination: URL) throws {
        let scratch = destination.deletingLastPathComponent()
            .appending(path: "\(destination.lastPathComponent).reverting")
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.copyItem(at: source, to: scratch)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: scratch)
            } else {
                try FileManager.default.moveItem(at: scratch, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
    }

    /// Forgets the original.
    ///
    /// Only a sidecar folino copied is deleted. When the original is the source file itself — a MusicXML import
    /// whose editor save went to a sibling `.mscz` — that file is the item's own history, and a re-read cannot
    /// happen for it anyway (re-read only exists for PDF-origin items).
    public func discardOriginal(
        for item: ScoreItem,
    ) async throws -> ScoreItem { // swiftlint:disable:this async_without_await
        guard let originalFileName = item.originalFileName else { return item }
        if originalFileName == item.originalSidecarFileName {
            try? FileManager.default.removeItem(at: scoresDirectory.appending(path: originalFileName))
        }
        var cleared = item
        cleared.originalFileName = nil
        cleared.originalContentHash = nil
        cleared.originalProvenance = nil
        return cleared
    }
}
