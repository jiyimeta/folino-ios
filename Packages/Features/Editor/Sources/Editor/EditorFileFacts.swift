import CryptoKit
import Foundation

/// SHA-256 + size of a file on disk, matching the importer's hex-digest format
/// (Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift:137-158).
enum EditorFileFacts {
    static func hashAndSize(of url: URL) throws -> (contentHash: String, sizeBytes: Int64) {
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
    }
}
