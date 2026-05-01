import Foundation

/// A cache record describing one (bank, program) SoundFont 2 patch on disk.
/// Bundled patches and downloaded patches both use this record; the
/// `isBundled` flag distinguishes them so the cache management UI can prevent
/// deletion of bundled patches.
public struct SoundfontPatch: Hashable, Sendable, Codable, Identifiable {
    public var id: SoundfontPatchKey { SoundfontPatchKey(bank: bank, program: program) }

    public let bank: Int
    public let program: Int
    public var localFileName: String
    public var sizeBytes: Int64
    public let downloadedAt: Date
    public var lastUsedAt: Date
    public var isBundled: Bool

    public init(
        bank: Int,
        program: Int,
        localFileName: String,
        sizeBytes: Int64,
        downloadedAt: Date,
        lastUsedAt: Date,
        isBundled: Bool = false
    ) {
        self.bank = bank
        self.program = program
        self.localFileName = localFileName
        self.sizeBytes = sizeBytes
        self.downloadedAt = downloadedAt
        self.lastUsedAt = lastUsedAt
        self.isBundled = isBundled
    }
}
