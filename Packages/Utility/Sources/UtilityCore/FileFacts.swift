#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// File identity facts the library rows persist: content hash + size. One definition — the importer, the
/// editor's save path, and score creation must all agree byte-for-byte on how these are computed.
///
/// **Apple-only, deliberately.** `CryptoKit` does not exist on Android, and this module is reachable from there:
/// `Domain` depends on `UtilityCore`, and every JNI target depends on `Domain`, so an unguarded import here fails
/// the cross-compile of all five `.so`s — which is exactly what it did, silently, from the day it landed until the
/// next time anyone built for Android.
///
/// Nothing is missing on the other side. Android reaches the same two facts through `FileFactsProviding`
/// (`EditorCore/EditorSeams.swift`), whose whole reason for existing is this: the digest comes from Kotlin, in the
/// same hex format `LibraryAndroidStore` already writes at import. The seam is the port; this is one of its two
/// implementations, and it is the one that only compiles where CryptoKit does.
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
#endif
