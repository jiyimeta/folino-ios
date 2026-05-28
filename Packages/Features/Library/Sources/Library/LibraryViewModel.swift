import Domain
import Foundation
import Observation

@MainActor
@Observable
public final class LibraryViewModel {
    let repository: any ScoreLibraryRepository
    let importer: any ScoreFileImporter
    let gateway: any ScoreFileGateway
    let shareService: any ScoreShareService

    var shareTarget: ShareTarget?
    var isPreparingShare = false

    /// True while a file import is in flight (prepare or commit). Driven by `defer` blocks in `startImport` and
    /// `commit` so it clears on success, duplicate detection, and any thrown error. The App composition root uses this
    /// to show a loading HUD over the whole shell.
    public var isImporting = false

    struct ShareTarget: Identifiable, Equatable {
        let id: UUID
        let urls: [URL]
        init(urls: [URL]) {
            id = UUID()
            self.urls = urls
        }
    }

    var errorAlertMessage: String?

    /// Set when an import succeeds; the App composition root watches this and pushes the Reader. Cleared by the watcher
    /// after handling.
    public var pendingScoreToOpen: ScoreItem?

    /// Drives the `.fileImporter` sheet.
    var isFileImporterPresented = false

    /// Dismiss any in-flight import-flow UI (file picker sheet, duplicate prompt, error alert). Called from the App
    /// layer when an external incoming action (file URL or share token) supersedes whatever the user was doing.
    public func dismissImportUI() {
        isFileImporterPresented = false
        duplicatePrompt = nil
        errorAlertMessage = nil
    }

    /// Set when `prepareImport` returns at least one duplicate. The view presents a 3-button alert; choosing one of the
    /// buttons drives `commitImport`.
    var duplicatePrompt: DuplicatePrompt?

    struct DuplicatePrompt: Identifiable, Equatable {
        let id = UUID()
        let plan: ImportPlan
        let existing: ScoreItem
    }

    public init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService,
    ) {
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
        self.shareService = shareService
    }

    func toggleFavorite(_ scoreItem: ScoreItem) async {
        var updated = scoreItem
        updated.isFavorite.toggle()
        await save(updated)
    }

    func rename(_ scoreItem: ScoreItem, to newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != scoreItem.title else { return }
        var updated = scoreItem
        updated.title = trimmed
        await save(updated)
    }

    func delete(_ scoreItem: ScoreItem) async {
        do {
            try await repository.deleteScoreItem(id: scoreItem.id)
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    func deletePlaylist(_ playlist: Playlist) async {
        do {
            try await repository.deletePlaylist(id: playlist.id)
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    func deleteTag(_ tag: Tag) async {
        do {
            try await repository.deleteTag(id: tag.id)
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    func bulkDelete(_ ids: Set<ScoreItemID>) async {
        for id in ids {
            do {
                try await repository.deleteScoreItem(id: id)
            } catch {
                errorAlertMessage = describe(error)
                return
            }
        }
    }

    func restore(_ scoreItem: ScoreItem) async {
        do {
            try await repository.restoreScoreItem(id: scoreItem.id)
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    func bulkRestore(_ ids: Set<ScoreItemID>) async {
        for id in ids {
            do {
                try await repository.restoreScoreItem(id: id)
            } catch {
                errorAlertMessage = describe(error)
                return
            }
        }
    }

    func permanentlyDelete(_ scoreItem: ScoreItem) async {
        do {
            try await repository.permanentlyDeleteScoreItem(id: scoreItem.id)
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    func bulkPermanentlyDelete(_ ids: Set<ScoreItemID>) async {
        for id in ids {
            do {
                try await repository.permanentlyDeleteScoreItem(id: id)
            } catch {
                errorAlertMessage = describe(error)
                return
            }
        }
    }

    func bulkRemoveFromPlaylist(
        _ ids: Set<ScoreItemID>,
        from playlist: Playlist,
    ) async {
        guard !ids.isEmpty else { return }
        var updated = playlist
        updated.orderedScoreItemIDs.removeAll { ids.contains($0) }
        guard updated.orderedScoreItemIDs != playlist.orderedScoreItemIDs else { return }
        do {
            try await repository.savePlaylist(updated)
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    func bulkAddToPlaylist(
        _ orderedIDs: [ScoreItemID],
        to playlist: Playlist,
    ) async {
        guard !orderedIDs.isEmpty else { return }
        let existing = Set(playlist.orderedScoreItemIDs)
        let toAppend = orderedIDs.filter { !existing.contains($0) }
        guard !toAppend.isEmpty else { return }
        var updated = playlist
        updated.orderedScoreItemIDs.append(contentsOf: toAppend)
        do {
            try await repository.savePlaylist(updated)
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    func bulkAddTags(
        _ ids: Set<ScoreItemID>,
        tagIDs: Set<TagID>,
    ) async {
        guard !ids.isEmpty, !tagIDs.isEmpty else { return }
        for id in ids {
            guard let item = repository.scoreItems.first(where: { $0.id == id }) else { continue }
            let merged = item.tagIDs.union(tagIDs)
            guard merged != item.tagIDs else { continue }
            var updated = item
            updated.tagIDs = merged
            do {
                try await repository.saveScoreItem(updated)
            } catch {
                errorAlertMessage = describe(error)
                return
            }
        }
    }

    func requestShare(_ item: ScoreItem, format: ScoreShareFormat) async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await shareService.prepareShare(item: item, format: format)
            shareTarget = ShareTarget(urls: [url])
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    func requestBulkShare(_ items: [ScoreItem], format: ScoreShareFormat) async {
        guard !items.isEmpty else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }
        var urls: [URL] = []
        urls.reserveCapacity(items.count)
        for item in items {
            do {
                let url = try await shareService.prepareShare(item: item, format: format)
                urls.append(url)
            } catch {
                errorAlertMessage = describe(error)
                return
            }
        }
        shareTarget = ShareTarget(urls: urls)
    }

    func setTagIDs(_ tagIDs: Set<TagID>, on scoreItem: ScoreItem) async {
        var updated = scoreItem
        updated.tagIDs = tagIDs
        await save(updated)
    }

    func createPlaylist(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let playlist = Playlist(name: trimmed, orderedScoreItemIDs: [], createdAt: Date())
        do {
            try await repository.savePlaylist(playlist)
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    func createTag(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tag = Tag(name: trimmed, colorHex: "#5856D6")
        do {
            try await repository.saveTag(tag)
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    func save(_ scoreItem: ScoreItem) async {
        do {
            try await repository.saveScoreItem(scoreItem)
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    /// Called by the `.fileImporter` `onCompletion`. Handles security-scoped access, prepareImport, and either commits
    /// immediately or stages a duplicate prompt.
    public func startImport(from sourceURL: URL) async {
        isImporting = true
        defer { isImporting = false }
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let plan: ImportPlan
        do {
            plan = try await importer.prepareImport(sourceURL: sourceURL)
        } catch {
            errorAlertMessage = describe(error)
            return
        }
        if let existing = plan.duplicates.first {
            duplicatePrompt = DuplicatePrompt(plan: plan, existing: existing)
            return
        }
        await commit(plan: plan, decision: .importAsNew)
    }

    func commit(plan: ImportPlan, decision: ImportDecision) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let item = try await importer.commitImport(plan, decision: decision)
            pendingScoreToOpen = item
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        if let domain = error as? DomainError {
            switch domain {
            case .unsupportedFormat:
                return String(localized: "library.import.error.unsupported", bundle: .module)
            case .scoreParseFailed:
                return String(localized: "library.import.error.invalidFile", bundle: .module)
            case .persistenceFailed:
                return String(localized: "library.import.error.saveFailed", bundle: .module)
            case let .scoreFileNotFound(name):
                return String(
                    localized: "library.error.fallback.scoreFileNotFound",
                    defaultValue: "Score file not found: \(name)",
                    bundle: .module,
                )
            case let .scoreWriteFailed(reason):
                return String(
                    localized: "library.error.fallback.scoreWriteFailed",
                    defaultValue: "Could not write score file: \(reason)",
                    bundle: .module,
                )
            case let .syncFailed(reason):
                return String(
                    localized: "library.error.fallback.syncFailed",
                    defaultValue: "Sync failed: \(reason)",
                    bundle: .module,
                )
            case let .audioEngineFailed(reason):
                return String(
                    localized: "library.error.fallback.audioEngineFailed",
                    defaultValue: "Audio engine error: \(reason)",
                    bundle: .module,
                )
            }
        }
        return (error as NSError).localizedDescription
    }
}
