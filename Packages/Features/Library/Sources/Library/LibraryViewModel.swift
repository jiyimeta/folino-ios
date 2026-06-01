import Domain
import Foundation
import Observation
import ScoreUI

@MainActor
@Observable
public final class LibraryViewModel {
    let repository: any ScoreLibraryRepository
    let importer: any ScoreFileImporter
    let gateway: any ScoreFileGateway
    let shareService: any ScoreShareService
    let metadataReader: any ScoreMetadataReading

    var shareTarget: ScoreShareTarget?
    var isPreparingShare = false

    /// True while a file import is in flight (prepare or commit). Driven by `defer` blocks in `startImport` and
    /// `commit` so it clears on success, duplicate detection, and any thrown error. The App composition root uses this
    /// to show a loading HUD over the whole shell.
    public var isImporting = false

    var currentError: Error?

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
        currentError = nil
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
        metadataReader: any ScoreMetadataReading,
    ) {
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
        self.shareService = shareService
        self.metadataReader = metadataReader
    }

    func toggleFavorite(_ scoreItem: ScoreItem) async {
        var updated = scoreItem
        updated.isFavorite.toggle()
        await save(updated)
    }

    /// Read the on-disk file's source + credit metaTags. Errors collapse to nil so a transient parse failure simply
    /// leaves the source label / pre-fill empty instead of blocking editing.
    public func loadFileMetadata(for item: ScoreItem) async -> ScoreFileMetadata? {
        try? await metadataReader.readMetadata(for: item)
    }

    /// Apply the edited fields to the item and persist. Title is required (trimmed, non-empty); other fields are stored
    /// trimmed, with empties persisted as `""` so they are treated as explicit user values, not "never edited".
    public func saveMetadata(_ item: ScoreItem, fields: EditableScoreInfo) async {
        let trimmedTitle = fields.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        var updated = item
        updated.title = trimmedTitle
        updated.subtitle = fields.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.composer = fields.composer.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.arranger = fields.arranger.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.lyricist = fields.lyricist.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.copyright = fields.copyright.trimmingCharacters(in: .whitespacesAndNewlines)
        await save(updated)
    }

    func delete(_ scoreItem: ScoreItem) async {
        do {
            try await repository.deleteScoreItem(id: scoreItem.id)
        } catch {
            currentError = error
        }
    }

    func deletePlaylist(_ playlist: Playlist) async {
        do {
            try await repository.deletePlaylist(id: playlist.id)
        } catch {
            currentError = error
        }
    }

    func deleteTag(_ tag: Tag) async {
        do {
            try await repository.deleteTag(id: tag.id)
        } catch {
            currentError = error
        }
    }

    func bulkDelete(_ ids: Set<ScoreItemID>) async {
        for id in ids {
            do {
                try await repository.deleteScoreItem(id: id)
            } catch {
                currentError = error
                return
            }
        }
    }

    func restore(_ scoreItem: ScoreItem) async {
        do {
            try await repository.restoreScoreItem(id: scoreItem.id)
        } catch {
            currentError = error
        }
    }

    func bulkRestore(_ ids: Set<ScoreItemID>) async {
        for id in ids {
            do {
                try await repository.restoreScoreItem(id: id)
            } catch {
                currentError = error
                return
            }
        }
    }

    func permanentlyDelete(_ scoreItem: ScoreItem) async {
        do {
            try await repository.permanentlyDeleteScoreItem(id: scoreItem.id)
        } catch {
            currentError = error
        }
    }

    func bulkPermanentlyDelete(_ ids: Set<ScoreItemID>) async {
        for id in ids {
            do {
                try await repository.permanentlyDeleteScoreItem(id: id)
            } catch {
                currentError = error
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
            currentError = error
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
            currentError = error
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
                currentError = error
                return
            }
        }
    }

    func requestShare(_ item: ScoreItem, format: ScoreShareFormat) async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await shareService.prepareShare(item: item, format: format)
            shareTarget = ScoreShareTarget(urls: [url])
        } catch {
            currentError = error
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
                currentError = error
                return
            }
        }
        shareTarget = ScoreShareTarget(urls: urls)
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
            currentError = error
        }
    }

    func createTag(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tag = Tag(name: trimmed, colorHex: "#5856D6")
        do {
            try await repository.saveTag(tag)
        } catch {
            currentError = error
        }
    }

    func save(_ scoreItem: ScoreItem) async {
        do {
            try await repository.saveScoreItem(scoreItem)
        } catch {
            currentError = error
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
            currentError = error
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
            currentError = error
        }
    }
}

extension LibraryViewModel: ScoreInfoEditing {}
