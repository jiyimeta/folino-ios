import Domain
import Foundation

/// Stages a prepared score file plus its `intent.json` for VocalTuner to pick up. The mirror image of VocalTuner's
/// `FolinoHandoffStager`, and pure `FileManager` for the same reason — the write path is the part worth testing,
/// and it should not need a device or a real App Group to test.
public struct OutgoingScoreStager: Sendable {
    public init() {}

    /// - Parameters:
    ///   - fileURL: the already-prepared export (`ScoreShareService.prepareShare`), whose bytes get copied.
    ///   - displayName: the score's user-facing title. Sanitized with `ScoreExportNaming` — the same rule
    ///     VocalTuner applies in the other direction — and given `fileURL`'s extension. VocalTuner addresses the
    ///     staged bytes by `originalName`, so the on-disk basename and `originalName` must stay identical.
    ///   - format: advisory `ScoreFormat`-style hint. The receiver re-derives the real format from the extension.
    ///   - token: opaque, URL-safe. Validated here before it becomes a path component, mirroring what the receiving
    ///     side does with an inbound token: everything below starts with a recursive delete at
    ///     `IncomingScoresVT/<token>`, and a traversal value like `"../.."` would aim that delete at the shared
    ///     container root.
    /// - Throws: `CocoaError(.fileWriteInvalidFileName)` for a token that is not a safe path component — thrown
    ///   before any filesystem work happens; every other error comes from `FileManager`.
    @discardableResult
    public func stage(
        fileURL: URL,
        displayName: String,
        format: String,
        token: String,
        into container: URL,
        now: Date,
        fileManager: FileManager = .default,
    ) throws -> IncomingScoreIntent {
        guard SharedScorePaths.isValidToken(token) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let root = SharedScorePaths.vocalTunerTokenURL(token: token, in: container)
        let filesDir = SharedScorePaths.vocalTunerTokenFilesURL(token: token, in: container)
        // Clear the whole token directory first: a retried hand-off on the same token must not leave the previous
        // export sitting next to the new one, where the receiver would import both.
        try? fileManager.removeItem(at: root)
        try fileManager.createDirectory(at: filesDir, withIntermediateDirectories: true)

        // Load-bearing: `ScoreExportNaming.sanitize` maps `/` and `\` to `_`, which is the only thing keeping an
        // arbitrary score title from escaping `files/` as a path component. The stager does not own that sanitizer.
        let stem = ScoreExportNaming.sanitize(title: displayName)
        let ext = fileURL.pathExtension
        let originalName = ext.isEmpty ? stem : "\(stem).\(ext)"
        let destination = filesDir.appending(path: originalName, directoryHint: .notDirectory)
        try fileManager.copyItem(at: fileURL, to: destination)

        let intent = IncomingScoreIntent(
            schemaVersion: 1,
            token: token,
            createdAt: now,
            source: "folino",
            openAfter: true,
            files: [
                .init(
                    relativePath: "\(SharedScorePaths.filesDirname)/\(originalName)",
                    originalName: originalName,
                    format: format,
                ),
            ],
        )
        let data = try IncomingScoreIntent.encoder().encode(intent)
        try data.write(
            to: SharedScorePaths.vocalTunerTokenIntentURL(token: token, in: container), options: .atomic,
        )
        return intent
    }
}

/// Reads VocalTuner's capability stamp out of the shared App Group container. Any failure — missing file,
/// unreadable bytes, malformed JSON — collapses to `nil`, which resolves to the share-sheet fallback rather than
/// to an error the user has to dismiss.
public struct VocalTunerCapabilityReader: Sendable {
    private let sharedContainer: URL

    public init(sharedContainer: URL) {
        self.sharedContainer = sharedContainer
    }

    public func read() -> VocalTunerCapabilities? {
        let url = SharedScorePaths.vocalTunerCapabilitiesURL(in: sharedContainer)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VocalTunerCapabilities.self, from: data)
    }
}
