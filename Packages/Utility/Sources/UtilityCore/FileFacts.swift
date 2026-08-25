import CryptoKit
import Foundation

/// File identity facts the library rows persist: content hash + size. One definition — the importer, the
/// editor's save path, and score creation must all agree byte-for-byte on how these are computed.
public enum FileFacts {
    /// SHA-256 + size of a file on disk, matching the importer's hex-digest format
    /// (Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift:137-158).
    public static func hashAndSize(of url: URL) throws -> (contentHash: String, sizeBytes: Int64) {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let chunkSize = 64 * 1024
        var total: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (hex, total)
    }
}
