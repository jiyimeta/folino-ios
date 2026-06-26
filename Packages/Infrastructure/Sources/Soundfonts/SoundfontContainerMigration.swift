import Foundation

/// One-time, idempotent reconcile of the high-quality SoundFont to a single copy in the shared App Group container.
/// Existence-driven (no "did I migrate" flag) so it self-heals and is safe to run on every launch. See the
/// shared-soundfont spec for the move-then-dedup invariant.
public struct SoundfontContainerMigration: Sendable {
    private nonisolated(unsafe) let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func reconcile(
        fileName: String,
        sharedDirectory: URL,
        legacyDirectory: URL,
        minimumValidByteSize: Int64,
    ) {
        // When the container is unavailable both resolve to the private dir — nothing to reconcile.
        guard sharedDirectory != legacyDirectory else { return }
        try? fileManager.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        excludeFromBackup(sharedDirectory)
        let sharedFile = sharedDirectory.appendingPathComponent(fileName)
        let legacyFile = legacyDirectory.appendingPathComponent(fileName)

        // ① Populate shared from a valid legacy copy when shared is empty/invalid (intra-volume rename: instant).
        if !isValid(sharedFile, minimumValidByteSize), isValid(legacyFile, minimumValidByteSize) {
            try? fileManager.removeItem(at: sharedFile)
            try? fileManager.moveItem(at: legacyFile, to: sharedFile)
            excludeFromBackup(sharedFile)
        }
        // ② Drop the redundant legacy copy once shared holds a valid file (the "sibling downloaded first" case).
        if isValid(sharedFile, minimumValidByteSize), fileManager.fileExists(atPath: legacyFile.path) {
            try? fileManager.removeItem(at: legacyFile)
        }
    }

    private func isValid(_ url: URL, _ minimumBytes: Int64) -> Bool {
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64 else { return false }
        return size >= minimumBytes
    }

    private func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}
