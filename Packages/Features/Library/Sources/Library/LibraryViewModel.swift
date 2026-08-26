import Domain
import Foundation
import Observation
import ScoreUI
import UtilityCore

@MainActor
@Observable
public final class LibraryViewModel {
    let repository: any ScoreLibraryRepository
    let originalStore: any ScoreOriginalStore
    let importer: any ScoreFileImporter
    let gateway: any ScoreFileGateway
    let shareService: any ScoreShareService
    let metadataReader: any ScoreMetadataReading
    let creator: any ScoreFileCreator
    /// Where `ScoreItem.localFileName` resolves against. Needed by the creation wizard's "same instrumentation as
    /// an existing score" step, which is the only Library flow that parses a score file itself — every other one
    /// hands the `ScoreItem` to an adapter (`shareService`, `metadataReader`) that owns the resolution.
    let scoresDirectory: URL
    let vocalTunerHandoff: any VocalTunerHandoff
    /// Analytics sink. Read by the Screens that mutate the repository directly (playlist/tag rename, reorder, single
    /// add/remove) so those view-layer bypass paths log against the same instance as the VM-owned actions.
    let analytics: any Analytics
    let crashReporter: any CrashReporter

    /// Logical origin label for every import that flows through the Library's in-app file picker.
    private static let importSource = "file_picker"

    var shareTarget: ScoreShareTarget?
    var isPreparingShare = false

    /// True while a file import is in flight (prepare or commit). Driven by `defer` blocks in `startImport` and
    /// `commit` so it clears on success, duplicate detection, and any thrown error. The App composition root uses this
    /// to show a loading HUD over the whole shell.
    public var isImporting = false

    var currentError: Error?

    /// Set when an import succeeds; the App watches this and pushes the Reader. Cleared by the watcher after handling.
    public var pendingScoreToOpen: ScoreItem?

    var isNewScoreSheetPresented = false
    /// Read together with `pendingScoreToOpen`: when true, the App opens the pushed Reader in an edit session.
    public private(set) var pendingOpenInEditSession = false

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
        originalStore: any ScoreOriginalStore,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService,
        metadataReader: any ScoreMetadataReading,
        creator: any ScoreFileCreator,
        scoresDirectory: URL,
        vocalTunerHandoff: any VocalTunerHandoff = NoopVocalTunerHandoff(),
        analytics: any Analytics = NoopAnalytics(),
        crashReporter: any CrashReporter = NoopCrashReporter(),
    ) {
        self.repository = repository
        self.originalStore = originalStore
        self.importer = importer
        self.gateway = gateway
        self.shareService = shareService
        self.metadataReader = metadataReader
        self.creator = creator
        self.scoresDirectory = scoresDirectory
        self.vocalTunerHandoff = vocalTunerHandoff
        self.analytics = analytics
        self.crashReporter = crashReporter
    }

    /// `source` is `.scoreRowMenu` for every in-Library caller (list rows, recents rows, context/swipe menus); the
    /// parameter keeps the surface explicit and ready for a future non-row origin.
    func toggleFavorite(_ scoreItem: ScoreItem, source: AnalyticsSource = .scoreRowMenu) async {
        var updated = scoreItem
        updated.isFavorite.toggle()
        do {
            try await repository.saveScoreItem(updated)
            analytics.log(.favoriteToggled(enabled: updated.isFavorite, source: source, mode: .single))
        } catch {
            currentError = error
        }
    }

    func bulkSetFavorite(_ ids: Set<ScoreItemID>, favorite: Bool) async {
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let item = repository.scoreItems.first(where: { $0.id == id }) else { continue }
            guard item.isFavorite != favorite else { continue }
            var updated = item
            updated.isFavorite = favorite
            do {
                try await repository.saveScoreItem(updated)
            } catch {
                currentError = error
                return
            }
        }
        analytics.log(.favoriteToggled(enabled: favorite, source: .bulkEdit, mode: .bulk))
    }

    /// Read the on-disk file's source + credit metaTags. Errors collapse to nil so a transient parse failure simply
    /// leaves the source label / pre-fill empty instead of blocking editing.
    public func loadFileMetadata(for item: ScoreItem) async -> ScoreFileMetadata? {
        try? await metadataReader.readMetadata(for: item)
    }

    /// Apply the edited fields to the item and persist. Title is required; all fields are trimmed and empties stored
    /// as `""`. Trim/validation is the shared `EditableScoreInfo.normalized()` rule (iOS + Android).
    public func saveMetadata(_ item: ScoreItem, fields: EditableScoreInfo) async {
        guard let n = fields.normalized() else { return }
        var updated = item
        updated.title = n.title
        updated.subtitle = n.subtitle
        updated.composer = n.composer
        updated.arranger = n.arranger
        updated.lyricist = n.lyricist
        updated.copyright = n.copyright
        await save(updated)
    }

    func delete(_ scoreItem: ScoreItem, source: AnalyticsSource = .scoreRowMenu) async {
        do {
            try await repository.deleteScoreItem(id: scoreItem.id)
            analytics.log(.scoreDeleted(source: source, mode: .single, count: 1))
        } catch {
            currentError = error
        }
    }

    func deletePlaylist(_ playlist: Playlist) async {
        do {
            try await repository.deletePlaylist(id: playlist.id)
            analytics.log(.playlistDeleted(source: .playlist))
        } catch {
            currentError = error
        }
    }

    func deleteTag(_ tag: Tag) async {
        do {
            try await repository.deleteTag(id: tag.id)
            analytics.log(.tagDeleted(source: .tag))
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
        guard !ids.isEmpty else { return }
        analytics.log(.scoreDeleted(source: .bulkEdit, mode: .bulk, count: ids.count))
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
        updated.remove(ids)
        guard updated.orderedScoreItemIDs != playlist.orderedScoreItemIDs else { return }
        let removedCount = playlist.orderedScoreItemIDs.count - updated.orderedScoreItemIDs.count
        do {
            try await repository.savePlaylist(updated)
            analytics.log(.scoreRemovedFromPlaylist(source: .bulkEdit, count: removedCount))
        } catch {
            currentError = error
        }
    }

    func bulkAddToPlaylist(
        _ orderedIDs: [ScoreItemID],
        to playlist: Playlist,
    ) async {
        guard !orderedIDs.isEmpty else { return }
        var updated = playlist
        updated.appendUnique(orderedIDs)
        guard updated.orderedScoreItemIDs != playlist.orderedScoreItemIDs else { return }
        let addedCount = updated.orderedScoreItemIDs.count - playlist.orderedScoreItemIDs.count
        do {
            try await repository.savePlaylist(updated)
            analytics.log(.scoreAddedToPlaylist(source: .bulkEdit, count: addedCount))
        } catch {
            currentError = error
        }
    }

    func bulkAddTags(
        _ ids: Set<ScoreItemID>,
        tagIDs: Set<TagID>,
    ) async {
        guard !ids.isEmpty, !tagIDs.isEmpty else { return }
        var changedCount = 0
        for id in ids {
            guard let item = repository.scoreItems.first(where: { $0.id == id }) else { continue }
            let merged = item.tagIDs.union(tagIDs)
            guard merged != item.tagIDs else { continue }
            var updated = item
            updated.tagIDs = merged
            do {
                try await repository.saveScoreItem(updated)
                changedCount += 1
            } catch {
                currentError = error
                return
            }
        }
        if changedCount > 0 {
            analytics.log(.tagAssigned(source: .bulkEdit, count: changedCount))
        }
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
            analytics.log(.playlistCreated(source: .playlist))
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
            analytics.log(.tagCreated(source: .tag))
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
            if scoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let plan: ImportPlan
        do {
            plan = try await importer.prepareImport(sourceURL: sourceURL)
        } catch {
            currentError = error
            let format = ScoreFormat.detect(filename: sourceURL.lastPathComponent)?.analyticsValue ?? "unknown"
            logImportFailed(format: format, error: error)
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
            analytics.log(.scoreImported(
                format: plan.format,
                source: Self.importSource,
                isDuplicate: !plan.duplicates.isEmpty,
                museScoreMajorVersion: item.museScoreMajorVersion,
            ))
        } catch {
            currentError = error
            logImportFailed(format: plan.format.analyticsValue, error: error)
        }
    }

    /// Builds a blank score from `form`'s template and hands it to `creator`, queuing it on `pendingScoreToOpen`
    /// (the same App watcher `startImport` uses) with `pendingOpenInEditSession` armed. An untitled form — or one
    /// whose instrumentation the user emptied — no-ops.
    ///
    /// Lives here rather than in `LibraryViewModel+NewScore.swift` because `pendingOpenInEditSession` is
    /// `private(set)`: only this file can arm it.
    func createScore(from form: NewScoreForm) async {
        guard let template = form.template() else { return }
        do {
            let item = try await creator.createScore(Score.blank(template))
            analytics.log(.scoreCreated())
            pendingOpenInEditSession = true
            pendingScoreToOpen = item
            isNewScoreSheetPresented = false
        } catch {
            crashReporter.record(error: error)
            currentError = ScoreCreationFailed()
        }
    }

    /// The App calls this when it consumes `pendingScoreToOpen`, so a later import doesn't inherit a stale arm.
    public func consumePendingOpenInEditSession() -> Bool {
        defer { pendingOpenInEditSession = false }
        return pendingOpenInEditSession
    }
}

extension LibraryViewModel: ScoreInfoEditing {}
