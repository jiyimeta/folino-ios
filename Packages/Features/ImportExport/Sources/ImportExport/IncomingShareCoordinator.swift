import Domain
import Foundation
import ImportExportAppGroup
import os
import UtilityCore

/// Drains share-extension-staged import tokens from the App Group container, imports each staged file through
/// `ScoreFileImporter`, and appends the resulting score items to a target playlist (existing or freshly created).
///
/// `drain(token:)` accepts either a specific token (foreground handoff from a `folino://...` URL) or `nil` (app-launch
/// sweep of every staged token in chronological order). The coordinator serializes concurrent calls so two
/// near-simultaneous handoffs cannot race on the same staged directory.
@MainActor
public final class IncomingShareCoordinator {
    private let importer: any ScoreFileImporter
    private let repository: any ScoreLibraryRepository
    private let appGroupContainer: URL
    private let clock: any Clock
    private let duplicateResolver: (any ImportDuplicateResolver)?
    private let crashReporter: any CrashReporter
    private let outcome: ShareImportOutcome
    private let logger = Logger(
        subsystem: "com.KeyNumber.Folino",
        category: "IncomingShareCoordinator",
    )
    private var inFlight: Task<DrainResult, Never>?

    /// Logical origin label for every import that arrives through the Share Extension (mirrors Library's
    /// `"file_picker"`). Kept distinct so analytics can separate share-sheet imports from in-app file-picker imports.
    private static let importSource = "share_ext"

    public init(
        importer: any ScoreFileImporter,
        repository: any ScoreLibraryRepository,
        appGroupContainer: URL,
        clock: any Clock,
        duplicateResolver: (any ImportDuplicateResolver)? = nil,
        analytics: any Analytics = NoopAnalytics(),
        crashReporter: any CrashReporter = NoopCrashReporter(),
    ) {
        self.importer = importer
        self.repository = repository
        self.appGroupContainer = appGroupContainer
        self.clock = clock
        self.duplicateResolver = duplicateResolver
        self.crashReporter = crashReporter
        outcome = ShareImportOutcome(analytics: analytics, crashReporter: crashReporter)
    }

    /// Drains a single token (when `token != nil`) or every staged token in chronological order (when `token == nil`).
    /// Always removes the per-token directory before returning, even on failure paths.
    public func drain(token: UUID?) async -> DrainResult {
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

    private func performDrain(token: UUID?) async -> DrainResult {
        if let token {
            return await drainOne(token: token)
        }
        return await drainAll()
    }

    private func drainAll() async -> DrainResult {
        let incomingDir = AppGroupPaths.incomingImportsURL(in: appGroupContainer)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: incomingDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
        ) else {
            return .empty
        }
        var pairs: [(UUID, Date)] = []
        for entry in entries {
            guard let token = UUID(uuidString: entry.lastPathComponent) else { continue }
            let intentURL = AppGroupPaths.tokenIntentURL(token: token, in: appGroupContainer)
            if let data = try? Data(contentsOf: intentURL),
               let intent = try? JSONDecoder().decode(IncomingShareIntent.self, from: data)
            {
                pairs.append((token, intent.createdAt))
            } else {
                try? FileManager.default.removeItem(at: entry)
            }
        }
        pairs.sort { $0.1 < $1.1 }
        var aggregatedImported: [ScoreItemID] = []
        var aggregatedSkipped: [Skip] = []
        var aggregatedOpenAfter: ScoreItem?
        var aggregatedCreatedPlaylistID: PlaylistID?
        var aggregatedTargetPlaylistID: PlaylistID?
        var aggregatedTargetPlaylistName: String?
        var aggregatedPlaylistCreateFailure: String?
        for (token, _) in pairs {
            let result = await drainOne(token: token)
            aggregatedImported.append(contentsOf: result.imported)
            aggregatedSkipped.append(contentsOf: result.skipped)
            if let openAfter = result.openAfter {
                aggregatedOpenAfter = openAfter
            }
            if let createdID = result.createdPlaylistID {
                aggregatedCreatedPlaylistID = createdID
            }
            if let targetID = result.targetPlaylistID {
                aggregatedTargetPlaylistID = targetID
            }
            if let targetName = result.targetPlaylistName {
                aggregatedTargetPlaylistName = targetName
            }
            if let failure = result.playlistCreateFailure {
                aggregatedPlaylistCreateFailure = failure
            }
        }
        return DrainResult(
            imported: aggregatedImported,
            skipped: aggregatedSkipped,
            openAfter: aggregatedOpenAfter,
            createdPlaylistID: aggregatedCreatedPlaylistID,
            targetPlaylistID: aggregatedTargetPlaylistID,
            targetPlaylistName: aggregatedTargetPlaylistName,
            playlistCreateFailure: aggregatedPlaylistCreateFailure,
        )
    }

    private func drainOne(token: UUID) async -> DrainResult {
        let tokenURL = AppGroupPaths.tokenURL(token: token, in: appGroupContainer)
        guard let intent = loadIntent(token: token) else {
            logger.error("intent.json missing/corrupt; scrubbing token \(token.uuidString)")
            try? FileManager.default.removeItem(at: tokenURL)
            return .empty
        }

        let filesDir = AppGroupPaths.tokenFilesURL(token: token, in: appGroupContainer)
        let files = intent.files.map {
            SharedImportFile(
                path: filesDir.appending(path: $0.originalName, directoryHint: .notDirectory).path,
                originalName: $0.originalName,
            )
        }
        let choice = Self.choice(from: intent)

        let iosImporter = IOSShareImporter(importer: importer, duplicateResolver: duplicateResolver, logger: logger)
        let playlistTarget = IOSSharePlaylistTarget(repository: repository, clock: clock, logger: logger)
        let coordinator = SharedImportCoordinator(importer: iosImporter, target: playlistTarget)

        let shared = await coordinator.run(files: files, choice: choice, openAfter: intent.openAfter)

        if let failedName = shared.playlistCreateFailureName {
            // Preserve the staged token on disk so the user can retry on the next drain (cold launch). The spec
            // mandates: nothing is imported, and the banner reports `Couldn't create playlist "<name>"`.
            crashReporter.record(error: ShareImportFailure.playlistCreateFailed)
            return DrainResult(
                imported: [],
                skipped: [],
                openAfter: nil,
                createdPlaylistID: nil,
                targetPlaylistID: nil,
                targetPlaylistName: failedName,
                playlistCreateFailure: failedName,
            )
        }

        outcome.log(shared, importer: iosImporter, source: Self.importSource)
        try? FileManager.default.removeItem(at: tokenURL)

        let imported = shared.importedIDs.compactMap { UUID(uuidString: $0).map(ScoreItemID.init(rawValue:)) }
        let skipped = shared.skipped.map(Skip.init)
        let openAfter = shared.openAfterID.flatMap { iosImporter.itemsByID[$0] }
        let createdID = shared.createdPlaylistID.flatMap { UUID(uuidString: $0).map(PlaylistID.init(rawValue:)) }
        let targetID = shared.targetPlaylistID.flatMap { UUID(uuidString: $0).map(PlaylistID.init(rawValue:)) }
        let targetName = shared.targetPlaylistID.flatMap { playlistTarget.namesByID[$0] }

        return DrainResult(
            imported: imported,
            skipped: skipped,
            openAfter: openAfter,
            createdPlaylistID: createdID,
            targetPlaylistID: targetID,
            targetPlaylistName: targetName,
        )
    }

    private static func choice(from intent: IncomingShareIntent) -> PlaylistChoice {
        if let id = intent.playlistID { return .existing(id) }
        if let name = intent.newPlaylistName, !name.isEmpty { return .createNew(name: name) }
        return .libraryOnly
    }

    // MARK: - Helpers

    private func loadIntent(token: UUID) -> IncomingShareIntent? {
        let intentURL = AppGroupPaths.tokenIntentURL(token: token, in: appGroupContainer)
        guard let data = try? Data(contentsOf: intentURL),
              let intent = try? JSONDecoder().decode(IncomingShareIntent.self, from: data)
        else {
            return nil
        }
        return intent
    }
}
