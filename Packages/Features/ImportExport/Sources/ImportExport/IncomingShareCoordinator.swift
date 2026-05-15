import Domain
import Foundation
import ImportExportAppGroup
import os
import UtilityCore

/// Drains share-extension-staged import tokens from the App Group container,
/// imports each staged file through `ScoreFileImporter`, and appends the
/// resulting score items to a target playlist (existing or freshly created).
///
/// `drain(token:)` accepts either a specific token (foreground handoff from
/// a `folino://...` URL) or `nil` (app-launch sweep of every staged token
/// in chronological order). The coordinator serializes concurrent calls so
/// two near-simultaneous handoffs cannot race on the same staged directory.
@MainActor
public final class IncomingShareCoordinator {
    private let importer: any ScoreFileImporter
    private let repository: any ScoreLibraryRepository
    private let appGroupContainer: URL
    private let clock: any Clock
    private let logger = Logger(
        subsystem: "com.KeyNumber.Folino",
        category: "IncomingShareCoordinator",
    )
    private var inFlight: Task<DrainResult, Never>?

    public init(
        importer: any ScoreFileImporter,
        repository: any ScoreLibraryRepository,
        appGroupContainer: URL,
        clock: any Clock,
    ) {
        self.importer = importer
        self.repository = repository
        self.appGroupContainer = appGroupContainer
        self.clock = clock
    }

    /// Drains a single token (when `token != nil`) or every staged token in
    /// chronological order (when `token == nil`). Always removes the
    /// per-token directory before returning, even on failure paths.
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
        var aggregatedOpenAfter: ScoreItemID?
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
        let resolution = await resolvePlaylist(intent: intent)
        if case let .failed(name, _) = resolution {
            // Preserve the staged token on disk so the user can retry on the
            // next drain (cold launch). The spec mandates: nothing is imported,
            // and the banner reports `Couldn't create playlist "<name>"`.
            return DrainResult(
                imported: [],
                skipped: [],
                openAfter: nil,
                createdPlaylistID: nil,
                targetPlaylistID: nil,
                targetPlaylistName: name,
                playlistCreateFailure: name,
            )
        }
        let importOutcome = await importFiles(intent: intent, token: token)
        let finalPlaylist = await appendImportsToPlaylist(
            current: resolution.playlist,
            imported: importOutcome.imported,
        )
        try? FileManager.default.removeItem(at: tokenURL)
        return DrainResult(
            imported: importOutcome.imported,
            skipped: importOutcome.skipped,
            openAfter: intent.openAfter ? importOutcome.lastOpenedID : nil,
            createdPlaylistID: resolution.createdPlaylistID,
            targetPlaylistID: finalPlaylist?.id,
            targetPlaylistName: finalPlaylist?.name,
        )
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

    private enum PlaylistResolution {
        case none
        case existing(Playlist)
        case created(Playlist)
        case failed(name: String, error: any Error)

        var playlist: Playlist? {
            switch self {
            case .none, .failed: nil
            case let .existing(p), let .created(p): p
            }
        }

        var createdPlaylistID: PlaylistID? {
            if case let .created(p) = self { return p.id }
            return nil
        }
    }

    private func resolvePlaylist(intent: IncomingShareIntent) async -> PlaylistResolution {
        if let existingID = intent.playlistID,
           let existing = repository.playlists.first(where: { $0.id == existingID })
        {
            return .existing(existing)
        }
        guard let newName = intent.newPlaylistName, !newName.isEmpty else {
            return .none
        }
        let playlist = Playlist(
            name: newName,
            orderedScoreItemIDs: [],
            createdAt: clock.now(),
        )
        do {
            try await repository.savePlaylist(playlist)
            return .created(playlist)
        } catch {
            logger.error("failed to create new playlist: \(String(describing: error))")
            return .failed(name: newName, error: error)
        }
    }

    private struct ImportOutcome {
        var imported: [ScoreItemID] = []
        var skipped: [Skip] = []
        var lastOpenedID: ScoreItemID?
    }

    private func importFiles(intent: IncomingShareIntent, token: UUID) async -> ImportOutcome {
        var outcome = ImportOutcome()
        let filesURL = AppGroupPaths.tokenFilesURL(token: token, in: appGroupContainer)
        for file in intent.files {
            let sourceURL = filesURL.appending(path: file.originalName, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                outcome.skipped.append(.init(
                    originalName: file.originalName,
                    reason: .unreadable(NSError(
                        domain: "ImportExport",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "missing staged file"],
                    )),
                ))
                continue
            }
            await importSingleFile(sourceURL: sourceURL, file: file, outcome: &outcome)
        }
        return outcome
    }

    private func importSingleFile(
        sourceURL: URL,
        file: IncomingShareIntent.File,
        outcome: inout ImportOutcome,
    ) async {
        do {
            let plan = try await importer.prepareImport(sourceURL: sourceURL)
            if let dup = plan.duplicates.first {
                outcome.skipped.append(.init(
                    originalName: file.originalName,
                    reason: .duplicate(existingID: dup.id, existingTitle: dup.title),
                ))
                outcome.lastOpenedID = dup.id
                _ = try? await importer.commitImport(plan, decision: .openExisting(dup.id))
            } else {
                let item = try await importer.commitImport(plan, decision: .importAsNew)
                outcome.imported.append(item.id)
                outcome.lastOpenedID = item.id
            }
        } catch {
            outcome.skipped.append(.init(
                originalName: file.originalName,
                reason: .parseFailed(error),
            ))
        }
    }

    private func appendImportsToPlaylist(
        current: Playlist?,
        imported: [ScoreItemID],
    ) async -> Playlist? {
        guard var playlist = current, !imported.isEmpty else { return current }
        playlist.orderedScoreItemIDs.append(contentsOf: imported)
        do {
            try await repository.savePlaylist(playlist)
            return playlist
        } catch {
            logger.error("failed to update playlist with imports: \(String(describing: error))")
            return current
        }
    }
}
