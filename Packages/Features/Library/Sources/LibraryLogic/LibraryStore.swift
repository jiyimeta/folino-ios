import Domain
import Foundation
import Observation

/// Platform-agnostic state and intent layer for the Library feature. Contains no SwiftUI or UIKit
/// imports; localized error messages live in the iOS `Library` target (`LibraryErrorPresentation.swift`).
@MainActor
@Observable
public final class LibraryStore {
    let repository: any ScoreLibraryRepository
    let importer: any ScoreFileImporter
    let gateway: any ScoreFileGateway
    let shareService: any ScoreShareService

    public var shareTarget: ShareTarget?
    public var isPreparingShare = false

    /// True while a file import is in flight (prepare or commit). Driven by `defer` blocks in `startImport` and
    /// `commit` so it clears on success, duplicate detection, and any thrown error. The App composition root uses
    /// this to show a loading HUD over the whole shell.
    public var isImporting = false

    public struct ShareTarget: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let urls: [URL]
        public init(urls: [URL]) {
            id = UUID()
            self.urls = urls
        }
    }

    /// Non-nil when an error occurs; cleared by `dismissImportUI` or when the user dismisses the alert.
    public var currentError: LibraryError?

    /// Set when an import succeeds; the App composition root watches this and pushes the Reader. Cleared by the
    /// watcher after handling.
    public var pendingScoreToOpen: ScoreItem?

    /// Drives the `.fileImporter` sheet.
    public var isFileImporterPresented = false

    /// Dismiss any in-flight import-flow UI (file picker sheet, duplicate prompt, error alert). Called from the App
    /// layer when an external incoming action (file URL or share token) supersedes whatever the user was doing.
    public func dismissImportUI() {
        isFileImporterPresented = false
        duplicatePrompt = nil
        currentError = nil
    }

    /// Set when `prepareImport` returns at least one duplicate. The view presents a 3-button alert; choosing one of
    /// the buttons drives `commitImport`.
    public var duplicatePrompt: DuplicatePrompt?

    public struct DuplicatePrompt: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let plan: ImportPlan
        public let existing: ScoreItem

        public init(plan: ImportPlan, existing: ScoreItem) {
            id = UUID()
            self.plan = plan
            self.existing = existing
        }
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

    // MARK: - Repository read-through accessors

    /// Live score items (not in trash). Forwarded from the observed repository so screens never need to reach through
    /// to `repository` directly.
    public var scoreItems: [ScoreItem] {
        repository.scoreItems
    }

    /// Items currently in the trash. Forwarded from the observed repository.
    public var deletedScoreItems: [ScoreItem] {
        repository.deletedScoreItems
    }

    /// All tags. Forwarded from the observed repository.
    public var tags: [Tag] {
        repository.tags
    }

    /// All playlists. Forwarded from the observed repository.
    public var playlists: [Playlist] {
        repository.playlists
    }

    // MARK: - Factory

    /// Create a `ScoreListStore` bound to this store's repository. Callers get a live, observable list without
    /// holding a direct reference to the underlying repository.
    public func makeScoreListStore(source: ScoreListStore.Source) -> ScoreListStore {
        ScoreListStore(source: source, repository: repository)
    }

    /// Create a `RecentlyDeletedStore` bound to this store's repository.
    public func makeRecentlyDeletedStore() -> RecentlyDeletedStore {
        RecentlyDeletedStore(repository: repository)
    }

    // MARK: - Share format helper

    /// Selectable share formats for the given score item. Forwarded from the internal `shareService` so callers never
    /// need a direct reference to the service.
    public func availableShareFormats(for item: ScoreItem) async -> [ScoreShareFormatOption] {
        await shareService.availableFormats(for: item)
    }

    // MARK: - Intent methods

    public func toggleFavorite(_ scoreItem: ScoreItem) async {
        var updated = scoreItem
        updated.isFavorite.toggle()
        await save(updated)
    }

    public func rename(_ scoreItem: ScoreItem, to newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != scoreItem.title else { return }
        var updated = scoreItem
        updated.title = trimmed
        await save(updated)
    }

    public func delete(_ scoreItem: ScoreItem) async {
        do {
            try await repository.deleteScoreItem(id: scoreItem.id)
        } catch {
            currentError = LibraryError.from(error)
        }
    }

    public func deletePlaylist(_ playlist: Playlist) async {
        do {
            try await repository.deletePlaylist(id: playlist.id)
        } catch {
            currentError = LibraryError.from(error)
        }
    }

    public func deleteTag(_ tag: Tag) async {
        do {
            try await repository.deleteTag(id: tag.id)
        } catch {
            currentError = LibraryError.from(error)
        }
    }

    public func bulkDelete(_ ids: Set<ScoreItemID>) async {
        for id in ids {
            do {
                try await repository.deleteScoreItem(id: id)
            } catch {
                currentError = LibraryError.from(error)
                return
            }
        }
    }

    public func restore(_ scoreItem: ScoreItem) async {
        do {
            try await repository.restoreScoreItem(id: scoreItem.id)
        } catch {
            currentError = LibraryError.from(error)
        }
    }

    public func bulkRestore(_ ids: Set<ScoreItemID>) async {
        for id in ids {
            do {
                try await repository.restoreScoreItem(id: id)
            } catch {
                currentError = LibraryError.from(error)
                return
            }
        }
    }

    public func permanentlyDelete(_ scoreItem: ScoreItem) async {
        do {
            try await repository.permanentlyDeleteScoreItem(id: scoreItem.id)
        } catch {
            currentError = LibraryError.from(error)
        }
    }

    public func bulkPermanentlyDelete(_ ids: Set<ScoreItemID>) async {
        for id in ids {
            do {
                try await repository.permanentlyDeleteScoreItem(id: id)
            } catch {
                currentError = LibraryError.from(error)
                return
            }
        }
    }

    public func bulkRemoveFromPlaylist(
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
            currentError = LibraryError.from(error)
        }
    }

    public func bulkAddToPlaylist(
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
            currentError = LibraryError.from(error)
        }
    }

    public func bulkAddTags(
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
                currentError = LibraryError.from(error)
                return
            }
        }
    }

    public func requestShare(_ item: ScoreItem, format: ScoreShareFormat) async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await shareService.prepareShare(item: item, format: format)
            shareTarget = ShareTarget(urls: [url])
        } catch {
            currentError = LibraryError.from(error)
        }
    }

    public func requestBulkShare(_ items: [ScoreItem], format: ScoreShareFormat) async {
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
                currentError = LibraryError.from(error)
                return
            }
        }
        shareTarget = ShareTarget(urls: urls)
    }

    public func setTagIDs(_ tagIDs: Set<TagID>, on scoreItem: ScoreItem) async {
        var updated = scoreItem
        updated.tagIDs = tagIDs
        await save(updated)
    }

    public func createPlaylist(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let playlist = Playlist(name: trimmed, orderedScoreItemIDs: [], createdAt: Date())
        do {
            try await repository.savePlaylist(playlist)
        } catch {
            currentError = LibraryError.from(error)
        }
    }

    public func createTag(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tag = Tag(name: trimmed, colorHex: "#5856D6")
        do {
            try await repository.saveTag(tag)
        } catch {
            currentError = LibraryError.from(error)
        }
    }

    /// Persist an existing playlist (e.g. after rename or member-order change). On failure, sets `currentError`.
    public func savePlaylist(_ playlist: Playlist) async {
        do {
            try await repository.savePlaylist(playlist)
        } catch {
            currentError = LibraryError.from(error)
        }
    }

    /// Persist an existing tag (e.g. after rename). On failure, sets `currentError`.
    public func saveTag(_ tag: Tag) async {
        do {
            try await repository.saveTag(tag)
        } catch {
            currentError = LibraryError.from(error)
        }
    }

    public func save(_ scoreItem: ScoreItem) async {
        do {
            try await repository.saveScoreItem(scoreItem)
        } catch {
            currentError = LibraryError.from(error)
        }
    }

    /// Called by the `.fileImporter` `onCompletion`. Handles security-scoped access, prepareImport, and either
    /// commits immediately or stages a duplicate prompt.
    public func startImport(from sourceURL: URL) async {
        isImporting = true
        defer { isImporting = false }
        #if !os(Android)
        // Security-scoped resource access is required on Apple platforms to read
        // URLs delivered via UIDocumentPickerViewController / .fileImporter.
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }
        #endif
        let plan: ImportPlan
        do {
            plan = try await importer.prepareImport(sourceURL: sourceURL)
        } catch {
            currentError = LibraryError.from(error)
            return
        }
        switch ImportPlanValidator.decision(for: plan) {
        case .commitAsNew:
            await commit(plan: plan, decision: .importAsNew)
        case let .promptForDuplicate(existing):
            duplicatePrompt = DuplicatePrompt(plan: plan, existing: existing)
        }
    }

    public func commit(plan: ImportPlan, decision: ImportDecision) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let item = try await importer.commitImport(plan, decision: decision)
            pendingScoreToOpen = item
        } catch {
            currentError = LibraryError.from(error)
        }
    }
}
