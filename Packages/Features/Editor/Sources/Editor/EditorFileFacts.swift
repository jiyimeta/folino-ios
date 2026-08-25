import Foundation
import UtilityCore

/// SHA-256 + size of a file on disk, matching the importer's hex-digest format
/// (Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift:137-158).
enum EditorFileFacts {
    static func hashAndSize(of url: URL) throws -> (contentHash: String, sizeBytes: Int64) {
        try FileFacts.hashAndSize(of: url)
    }
}
