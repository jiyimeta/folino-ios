import Domain
import Foundation
import os
import UtilityCore

/// iOS importer adapter: stages via `ScoreFileImporter`, applies the duplicate resolver, and records every committed /
/// existing `ScoreItem` by id so the coordinator's `openAfterID` can be mapped back to a full item later.
@MainActor
final class IOSShareImporter: @preconcurrency SharedImportFileImporting {
    private let importer: any ScoreFileImporter
    private let duplicateResolver: (any ImportDuplicateResolver)?
    private let logger: Logger
    /// id (UUID string) -> resolved ScoreItem, for DrainResult.openAfter mapping.
    private(set) var itemsByID: [String: ScoreItem] = [:]

    init(importer: any ScoreFileImporter, duplicateResolver: (any ImportDuplicateResolver)?, logger: Logger) {
        self.importer = importer
        self.duplicateResolver = duplicateResolver
        self.logger = logger
    }

    func importFile(_ file: SharedImportFile, isMultiFile: Bool) async -> SharedImportFileResult {
        let sourceURL = URL(fileURLWithPath: file.path)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return .skipped(.missingFile) }
        do {
            let plan = try await importer.prepareImport(sourceURL: sourceURL)
            guard let dup = plan.duplicates.first else {
                let item = try await importer.commitImport(plan, decision: .importAsNew)
                itemsByID[item.id.rawValue.uuidString] = item
                return .imported(id: item.id.rawValue.uuidString)
            }
            return await resolve(plan: plan, dup: dup, isMultiFile: isMultiFile)
        } catch {
            return .skipped(.parseFailed)
        }
    }

    private func resolve(plan: ImportPlan, dup: ScoreItem, isMultiFile: Bool) async -> SharedImportFileResult {
        let decision: ImportDecision? = if let duplicateResolver {
            await duplicateResolver.resolveDuplicate(plan: plan, existing: dup, isMultiFile: isMultiFile)
        } else {
            .openExisting(dup.id)
        }
        guard let decision else {
            return .duplicate(existingID: dup.id.rawValue.uuidString, existingTitle: dup.title)
        }
        do {
            let item = try await importer.commitImport(plan, decision: decision)
            itemsByID[item.id.rawValue.uuidString] = item
            switch decision {
            case .importAsNew:
                return .imported(id: item.id.rawValue.uuidString)
            case .openExisting:
                return .duplicate(existingID: dup.id.rawValue.uuidString, existingTitle: dup.title)
            }
        } catch {
            return .skipped(.persistenceFailed)
        }
    }
}

/// iOS playlist adapter over `ScoreLibraryRepository`. Records created/targeted playlist names so the coordinator's
/// ids map back to names for the drain result banner.
@MainActor
final class IOSSharePlaylistTarget: @preconcurrency SharedImportPlaylistTargeting {
    private let repository: any ScoreLibraryRepository
    private let clock: any Clock
    private let logger: Logger
    private(set) var namesByID: [String: String] = [:]

    init(repository: any ScoreLibraryRepository, clock: any Clock, logger: Logger) {
        self.repository = repository
        self.clock = clock
        self.logger = logger
    }

    func playlistExists(id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        if let p = repository.playlists.first(where: { $0.id == PlaylistID(rawValue: uuid) }) {
            namesByID[id] = p.name
            return true
        }
        return false
    }

    func createPlaylist(name: String) async -> String? {
        let playlist = Playlist(name: name, orderedScoreItemIDs: [], createdAt: clock.now())
        do {
            try await repository.savePlaylist(playlist)
            let id = playlist.id.rawValue.uuidString
            namesByID[id] = name
            return id
        } catch {
            logger.error("failed to create playlist: \(String(describing: error))")
            return nil
        }
    }

    func append(scoreIDs: [String], toPlaylistID id: String) async {
        guard let uuid = UUID(uuidString: id),
              var playlist = repository.playlists.first(where: { $0.id == PlaylistID(rawValue: uuid) })
        else { return }
        let ids = scoreIDs.compactMap { raw -> ScoreItemID? in
            guard let uuid = UUID(uuidString: raw) else { return nil }
            return ScoreItemID(rawValue: uuid)
        }
        playlist.orderedScoreItemIDs.append(contentsOf: ids)
        do {
            try await repository.savePlaylist(playlist)
            namesByID[id] = playlist.name
        } catch {
            logger.error("failed to append to playlist: \(String(describing: error))")
        }
    }
}
