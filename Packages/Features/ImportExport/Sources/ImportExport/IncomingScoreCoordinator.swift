import Domain
import Foundation
import ImportExportAppGroup
import os
import UtilityCore

/// Drains cross-app score hand-offs a sibling app staged in the **shared** App Group container, imports each staged
/// file through `ScoreFileImporter`, and reports what to open.
///
/// The sibling writes `IncomingScores/<token>/{intent.json, files/…}` and opens `folino://open-score?token=<token>`.
/// `drain(token:)` takes that token (foreground hand-off) or `nil` (sweep every staged token, oldest first, picking up
/// hand-offs whose URL never landed). Concurrent calls are serialized so two near-simultaneous hand-offs cannot race
/// on the same staged directory, and the per-token directory is always scrubbed before returning — a corrupt hand-off
/// cannot wedge the queue.
///
/// Deliberately separate from `IncomingShareCoordinator`, which drains folino's *private* group in the
/// Share-Extension format: different container, different intent schema (`String` token, ISO-8601 dates), and no
/// playlist targeting — the cross-app contract has no playlist concept, so every hand-off lands in the library root.
@MainActor
public final class IncomingScoreCoordinator {
    private let importer: any ScoreFileImporter
    private let sharedContainer: URL
    private let outcome: ShareImportOutcome
    private let logger = Logger(
        subsystem: "com.KeyNumber.Folino",
        category: "IncomingScoreCoordinator",
    )
    private var inFlight: Task<DrainResult, Never>?

    public init(
        importer: any ScoreFileImporter,
        sharedContainer: URL,
        analytics: any Analytics = NoopAnalytics(),
        crashReporter: any CrashReporter = NoopCrashReporter(),
    ) {
        self.importer = importer
        self.sharedContainer = sharedContainer
        outcome = ShareImportOutcome(analytics: analytics, crashReporter: crashReporter)
    }

    /// Drains a single token (when `token != nil`) or every staged token in chronological order (when `token == nil`).
    public func drain(token: String?) async -> DrainResult {
        if let inFlight {
            _ = await inFlight.value
        }
        let task = Task<DrainResult, Never> { @MainActor in
            await self.performDrain(token: token)
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func performDrain(token: String?) async -> DrainResult {
        if let token {
            return await drainOne(token: token)
        }
        return await drainAll()
    }

    private func drainAll() async -> DrainResult {
        let incomingDir = SharedScorePaths.incomingScoresURL(in: sharedContainer)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: incomingDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
        ) else {
            return .empty
        }
        var pairs: [(String, Date)] = []
        for entry in entries {
            let token = entry.lastPathComponent
            guard SharedScorePaths.isValidToken(token) else { continue }
            if let intent = loadIntent(token: token) {
                pairs.append((token, intent.createdAt))
            } else {
                try? FileManager.default.removeItem(at: entry)
            }
        }
        pairs.sort { $0.1 < $1.1 }

        var aggregatedImported: [ScoreItemID] = []
        var aggregatedSkipped: [Skip] = []
        var aggregatedOpenAfter: ScoreItem?
        for (token, _) in pairs {
            let result = await drainOne(token: token)
            aggregatedImported.append(contentsOf: result.imported)
            aggregatedSkipped.append(contentsOf: result.skipped)
            if let openAfter = result.openAfter {
                aggregatedOpenAfter = openAfter
            }
        }
        return Self.result(imported: aggregatedImported, skipped: aggregatedSkipped, openAfter: aggregatedOpenAfter)
    }

    private func drainOne(token: String) async -> DrainResult {
        guard SharedScorePaths.isValidToken(token) else {
            logger.error("rejected malformed open-score token")
            return .empty
        }
        let tokenURL = SharedScorePaths.tokenURL(token: token, in: sharedContainer)
        guard let intent = loadIntent(token: token) else {
            logger.error("intent.json missing/corrupt; scrubbing token \(token, privacy: .public)")
            try? FileManager.default.removeItem(at: tokenURL)
            return .empty
        }

        // The staged bytes are addressed by `originalName` inside the token's `files/` directory (which is what
        // `relativePath` spells out too), keeping the extension the format detection keys off.
        let filesDir = SharedScorePaths.tokenFilesURL(token: token, in: sharedContainer)
        let files = intent.files.map {
            SharedImportFile(
                path: filesDir.appending(path: $0.originalName, directoryHint: .notDirectory).path,
                originalName: $0.originalName,
            )
        }

        // No duplicate resolver: a one-tap hand-off must not stop to ask. `IOSShareImporter` then resolves a
        // duplicate to `.openExisting`, so a score handed over twice opens the copy already in the library.
        let iosImporter = IOSShareImporter(importer: importer, duplicateResolver: nil, logger: logger)
        let coordinator = SharedImportCoordinator(importer: iosImporter, target: NoPlaylistTarget())
        let shared = await coordinator.run(files: files, choice: .libraryOnly, openAfter: intent.openAfter)

        outcome.log(shared, importer: iosImporter, source: Self.analyticsSource(from: intent.source))
        try? FileManager.default.removeItem(at: tokenURL)

        return Self.result(
            imported: shared.importedIDs.compactMap { UUID(uuidString: $0).map(ScoreItemID.init(rawValue:)) },
            skipped: shared.skipped.map(Skip.init),
            openAfter: shared.openAfterID.flatMap { iosImporter.itemsByID[$0] },
        )
    }

    /// The cross-app contract has no playlist fields, so every hand-off resolves to `.libraryOnly` and
    /// `SharedImportCoordinator` never reaches for a playlist. This target exists only to satisfy the protocol.
    private struct NoPlaylistTarget: SharedImportPlaylistTargeting {
        // swiftlint:disable async_without_await
        func playlistExists(id _: String) async -> Bool {
            false
        }

        func createPlaylist(name _: String) async -> String? {
            nil
        }

        func append(scoreIDs _: [String], toPlaylistID _: String) async {}
        // swiftlint:enable async_without_await
    }

    /// `source` is written by another app, so it is clamped to a short lowercase identifier before it becomes an
    /// analytics parameter — a renamed or malformed value must not silently fan the `score_imported` event out into
    /// unbounded cardinality.
    private static func analyticsSource(from raw: String) -> String {
        let normalized = raw.lowercased().prefix(24)
        guard !normalized.isEmpty,
              normalized.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        else {
            return "unknown"
        }
        return String(normalized)
    }

    private static func result(imported: [ScoreItemID], skipped: [Skip], openAfter: ScoreItem?) -> DrainResult {
        DrainResult(
            imported: imported,
            skipped: skipped,
            openAfter: openAfter,
            createdPlaylistID: nil,
            targetPlaylistID: nil,
            targetPlaylistName: nil,
        )
    }

    private func loadIntent(token: String) -> IncomingScoreIntent? {
        let intentURL = SharedScorePaths.tokenIntentURL(token: token, in: sharedContainer)
        guard let data = try? Data(contentsOf: intentURL),
              let intent = try? IncomingScoreIntent.decoder().decode(IncomingScoreIntent.self, from: data)
        else {
            return nil
        }
        return intent
    }
}
