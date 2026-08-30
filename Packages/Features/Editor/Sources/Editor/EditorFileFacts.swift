import EditorCore
import Foundation
import UtilityCore

/// SHA-256 + size of a file on disk, matching the importer's hex-digest format
/// (Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift:137-158).
///
/// The Apple half of `FileFactsProviding`. The digest itself lives in `UtilityCore.FileFacts`, which the importer
/// and score creation call too — one definition, because the format it produces is the contract and Android's
/// Kotlin digest has to match it byte for byte. What keeps this adapter out of `EditorCore` is that `FileFacts`
/// reaches for `CryptoKit`.
struct EditorFileFacts: FileFactsProviding {
    func hashAndSize(of url: URL) throws -> (contentHash: String, sizeBytes: Int64) {
        try FileFacts.hashAndSize(of: url)
    }
}
