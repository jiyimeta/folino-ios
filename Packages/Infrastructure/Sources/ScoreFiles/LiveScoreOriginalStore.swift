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

    // Conforms to an async protocol requirement, but every operation here — FileManager, FileHandle — is
    // synchronous, so the body never awaits.
    // swiftlint:disable:next async_without_await
    public func captureOriginalIfNeeded(for item: ScoreItem) async throws -> ScoreItem {
        let plan = OriginalCapture.plan(for: item, adoptableSourceFileName: adoptableSourceFileName(for: item))
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
            // The sidecar's existence is the marker, so re-check it here rather than trusting the row: a capture
            // whose row update was lost must find the file and adopt it, not copy the edited bytes over it.
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
    }

    /// The first candidate that is actually on disk — an untouched import file left beside an edited `.mscz`.
    private func adoptableSourceFileName(for item: ScoreItem) -> String? {
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

    // swiftlint:disable:next async_without_await
    public func revertToOriginal(_ item: ScoreItem, restoringScoreInfo _: Bool) async throws -> ScoreItem {
        // Implemented in Task 7.
        item
    }

    // swiftlint:disable:next async_without_await
    public func discardOriginal(for item: ScoreItem) async throws -> ScoreItem {
        // Implemented in Task 8.
        item
    }
}
