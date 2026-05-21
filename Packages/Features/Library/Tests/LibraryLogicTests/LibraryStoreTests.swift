import Domain
import Foundation
import LibraryLogic
import Testing

@MainActor
struct LibraryStoreTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(title: String = "A", isFavorite: Bool = false) -> ScoreItem {
        ScoreItem(
            title: title, composer: nil, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base, lastOpenedAt: nil, tagIDs: [], isFavorite: isFavorite,
        )
    }

    private struct Fixture {
        let store: LibraryStore
        let repo: FakeScoreLibraryRepository
        let importer: FakeScoreFileImporter
        let gateway: FakeScoreFileGateway
        let share: FakeScoreShareService
    }

    private static func makeStore(scoreItems: [ScoreItem] = []) -> Fixture {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = scoreItems
        let importer = FakeScoreFileImporter()
        let gateway = FakeScoreFileGateway()
        let share = FakeScoreShareService()
        let store = LibraryStore(
            repository: repo, importer: importer, gateway: gateway, shareService: share,
        )
        return Fixture(store: store, repo: repo, importer: importer, gateway: gateway, share: share)
    }

    // MARK: - toggleFavorite

    @Test func `toggle favorite flips and saves`() async {
        let original = Self.makeItem(isFavorite: false)
        let f = Self.makeStore(scoreItems: [original])
        await f.store.toggleFavorite(original)
        #expect(f.repo.savedScoreItems.last?.isFavorite == true)
        #expect(f.repo.scoreItems.first?.isFavorite == true)
    }

    // MARK: - rename

    @Test func `rename trims whitespace and saves`() async {
        let item = Self.makeItem(title: "Old")
        let f = Self.makeStore(scoreItems: [item])
        await f.store.rename(item, to: "  New  ")
        #expect(f.repo.savedScoreItems.last?.title == "New")
    }

    @Test func `rename empty title is no op`() async {
        let item = Self.makeItem(title: "Old")
        let f = Self.makeStore(scoreItems: [item])
        await f.store.rename(item, to: "   ")
        #expect(f.repo.savedScoreItems.isEmpty)
    }

    @Test func `rename same title is no op`() async {
        let item = Self.makeItem(title: "Same")
        let f = Self.makeStore(scoreItems: [item])
        await f.store.rename(item, to: "Same")
        #expect(f.repo.savedScoreItems.isEmpty)
    }

    // MARK: - delete

    @Test func `delete soft deletes via repository`() async {
        let item = Self.makeItem()
        let f = Self.makeStore(scoreItems: [item])
        await f.store.delete(item)
        #expect(f.repo.deletedScoreItemIDs == [item.id])
        #expect(f.repo.softDeletedScoreItemIDs == [item.id])
        #expect(f.repo.permanentlyDeletedScoreItemIDs.isEmpty)
        #expect(f.repo.scoreItems.isEmpty)
        #expect(f.repo.deletedScoreItems.count == 1)
    }

    @Test func `delete failure sets currentError as domain persistenceFailed`() async {
        let item = Self.makeItem()
        let f = Self.makeStore(scoreItems: [item])
        f.repo.deleteScoreItemError = .persistenceFailed(reason: "io error")
        await f.store.delete(item)
        #expect(f.store.currentError == .domain(.persistenceFailed(reason: "io error")))
    }

    // MARK: - restore

    @Test func `restore calls repository restore`() async throws {
        let item = Self.makeItem()
        let f = Self.makeStore(scoreItems: [item])
        await f.store.delete(item)
        let trashed = try #require(f.repo.deletedScoreItems.first)
        await f.store.restore(trashed)
        #expect(f.repo.restoredScoreItemIDs == [item.id])
        #expect(f.repo.scoreItems.count == 1)
        #expect(f.repo.deletedScoreItems.isEmpty)
    }

    // MARK: - permanentlyDelete

    @Test func `permanently delete calls repository permanently delete`() async throws {
        let item = Self.makeItem()
        let f = Self.makeStore(scoreItems: [item])
        await f.store.delete(item)
        let trashed = try #require(f.repo.deletedScoreItems.first)
        await f.store.permanentlyDelete(trashed)
        #expect(f.repo.permanentlyDeletedScoreItemIDs == [item.id])
        #expect(f.repo.scoreItems.isEmpty)
        #expect(f.repo.deletedScoreItems.isEmpty)
    }

    // MARK: - setTagIDs

    @Test func `set tag IDs resyncs and saves`() async {
        let item = Self.makeItem()
        let f = Self.makeStore(scoreItems: [item])
        let tagID = TagID()
        await f.store.setTagIDs([tagID], on: item)
        #expect(f.repo.savedScoreItems.last?.tagIDs == [tagID])
    }

    // MARK: - save error

    @Test func `save surfaces persistence error as currentError`() async {
        let item = Self.makeItem()
        let f = Self.makeStore(scoreItems: [item])
        f.repo.saveScoreItemError = .persistenceFailed(reason: "disk full")
        await f.store.toggleFavorite(item)
        #expect(f.store.currentError == .domain(.persistenceFailed(reason: "disk full")))
    }

    // MARK: - createPlaylist

    @Test func `create playlist trimmed non empty persists`() async {
        let f = Self.makeStore()
        await f.store.createPlaylist(name: "  Recital  ")
        #expect(f.repo.savedPlaylists.count == 1)
        #expect(f.repo.savedPlaylists.first?.name == "Recital")
        #expect(f.repo.savedPlaylists.first?.orderedScoreItemIDs.isEmpty == true)
    }

    @Test func `create playlist empty name no op`() async {
        let f = Self.makeStore()
        await f.store.createPlaylist(name: "   ")
        #expect(f.repo.savedPlaylists.isEmpty)
    }

    // MARK: - createTag

    @Test func `create tag trimmed non empty persists with default color`() async {
        let f = Self.makeStore()
        await f.store.createTag(name: "  Practice  ")
        #expect(f.repo.savedTags.count == 1)
        #expect(f.repo.savedTags.first?.name == "Practice")
        #expect(f.repo.savedTags.first?.colorHex == "#5856D6")
    }

    @Test func `create tag empty name no op`() async {
        let f = Self.makeStore()
        await f.store.createTag(name: "")
        #expect(f.repo.savedTags.isEmpty)
    }

    // MARK: - deletePlaylist

    @Test func `delete playlist calls repository`() async {
        let f = Self.makeStore()
        let playlist = Playlist(name: "P", orderedScoreItemIDs: [], createdAt: Self.base)
        f.repo.playlists = [playlist]
        await f.store.deletePlaylist(playlist)
        #expect(f.repo.deletedPlaylistIDs == [playlist.id])
        #expect(f.repo.playlists.isEmpty)
        #expect(f.store.currentError == nil)
    }

    @Test func `delete playlist surfaces persistence error as currentError`() async {
        let f = Self.makeStore()
        let playlist = Playlist(name: "P", orderedScoreItemIDs: [], createdAt: Self.base)
        f.repo.playlists = [playlist]
        f.repo.deletePlaylistError = .persistenceFailed(reason: "io error")
        await f.store.deletePlaylist(playlist)
        #expect(f.store.currentError == .domain(.persistenceFailed(reason: "io error")))
    }

    // MARK: - deleteTag

    @Test func `delete tag calls repository`() async {
        let f = Self.makeStore()
        let tag = Tag(name: "T", colorHex: "#5856D6")
        f.repo.tags = [tag]
        await f.store.deleteTag(tag)
        #expect(f.repo.deletedTagIDs == [tag.id])
        #expect(f.repo.tags.isEmpty)
        #expect(f.store.currentError == nil)
    }

    @Test func `delete tag surfaces persistence error as currentError`() async {
        let f = Self.makeStore()
        let tag = Tag(name: "T", colorHex: "#5856D6")
        f.repo.tags = [tag]
        f.repo.deleteTagError = .persistenceFailed(reason: "io error")
        await f.store.deleteTag(tag)
        #expect(f.store.currentError == .domain(.persistenceFailed(reason: "io error")))
    }

    // MARK: - import

    private static func makePlan(duplicates: [ScoreItem] = []) -> ImportPlan {
        ImportPlan(
            sourceURL: URL(filePath: "/tmp/x.mscx"),
            stagedURL: URL(filePath: "/tmp/staged-x.mscx"),
            format: .mscx,
            summary: ScoreFileSummary(
                title: "Imported", composer: nil,
                instrumentationSummary: "", lengthBeats: 0,
                defaultTempoBpm: 120, primaryKey: nil,
            ),
            contentHash: "hash",
            sizeBytes: 100,
            duplicates: duplicates,
        )
    }

    @Test func `happy path import pushes pending open`() async {
        let f = Self.makeStore()
        let plan = Self.makePlan()
        f.importer.preparedPlans = [plan]
        let imported = Self.makeItem(title: "Imported")
        f.importer.commitFactory = { _, _ in imported }

        await f.store.startImport(from: plan.sourceURL)
        #expect(f.importer.committed.count == 1)
        if case .importAsNew = f.importer.committed.first?.decision {} else {
            Issue.record("expected .importAsNew")
        }
        #expect(f.store.pendingScoreToOpen?.id == imported.id)
        #expect(f.store.duplicatePrompt == nil)
        #expect(f.store.currentError == nil)
    }

    @Test func `duplicate stages prompt instead of committing`() async {
        let f = Self.makeStore()
        let existing = Self.makeItem(title: "Existing")
        let plan = Self.makePlan(duplicates: [existing])
        f.importer.preparedPlans = [plan]
        f.importer.commitFactory = { _, _ in existing }

        await f.store.startImport(from: plan.sourceURL)
        #expect(f.importer.committed.isEmpty)
        #expect(f.store.duplicatePrompt?.existing.id == existing.id)
        #expect(f.store.pendingScoreToOpen == nil)
    }

    @Test func `commit open existing returns existing item`() async {
        let f = Self.makeStore()
        let existing = Self.makeItem(title: "Existing")
        let plan = Self.makePlan(duplicates: [existing])
        let differentItem = Self.makeItem(title: "DifferentItem")
        f.importer.commitFactory = { _, decision in
            if case .openExisting = decision { return existing }
            return differentItem
        }

        await f.store.commit(plan: plan, decision: .openExisting(existing.id))
        #expect(f.store.pendingScoreToOpen?.id == existing.id)
    }

    @Test func `commit import as new produces new item`() async {
        let f = Self.makeStore()
        let existing = Self.makeItem(title: "Existing")
        let plan = Self.makePlan(duplicates: [existing])
        let new = Self.makeItem(title: "New")
        f.importer.commitFactory = { _, decision in
            if case .importAsNew = decision { return new }
            return existing
        }

        await f.store.commit(plan: plan, decision: .importAsNew)
        #expect(f.store.pendingScoreToOpen?.id == new.id)
    }

    @Test func `unsupported format error sets currentError domain unsupportedFormat`() async {
        let f = Self.makeStore()
        f.importer.prepareImportErrors = [.unsupportedFormat("xyz")]
        await f.store.startImport(from: URL(filePath: "/tmp/x.xyz"))
        #expect(f.store.currentError == .domain(.unsupportedFormat("xyz")))
    }

    @Test func `parse error sets currentError domain scoreParseFailed`() async {
        let f = Self.makeStore()
        f.importer.prepareImportErrors = [.scoreParseFailed(reason: "bad bytes")]
        await f.store.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.store.currentError == .domain(.scoreParseFailed(reason: "bad bytes")))
    }

    @Test func `persistence error on commit sets currentError domain persistenceFailed`() async {
        let f = Self.makeStore()
        f.importer.preparedPlans = [Self.makePlan()]
        f.importer.commitImportError = .persistenceFailed(reason: "disk full")
        await f.store.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.store.currentError == .domain(.persistenceFailed(reason: "disk full")))
    }

    // MARK: - isImporting lifecycle

    @Test func `is importing starts false`() {
        let f = Self.makeStore()
        #expect(f.store.isImporting == false)
    }

    @Test func `start import clears is importing on success`() async {
        let f = Self.makeStore()
        f.importer.preparedPlans = [Self.makePlan()]
        let imported = Self.makeItem(title: "Imported")
        f.importer.commitFactory = { _, _ in imported }
        await f.store.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.store.isImporting == false)
    }

    @Test func `start import clears is importing on duplicate`() async {
        let f = Self.makeStore()
        let existing = Self.makeItem(title: "Existing")
        f.importer.preparedPlans = [Self.makePlan(duplicates: [existing])]
        await f.store.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.store.duplicatePrompt != nil)
        #expect(f.store.isImporting == false)
    }

    @Test func `start import clears is importing on prepare error`() async {
        let f = Self.makeStore()
        f.importer.prepareImportErrors = [.scoreParseFailed(reason: "bad")]
        await f.store.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.store.currentError != nil)
        #expect(f.store.isImporting == false)
    }

    @Test func `commit clears is importing on success`() async {
        let f = Self.makeStore()
        let plan = Self.makePlan()
        let item = Self.makeItem(title: "X")
        f.importer.commitFactory = { _, _ in item }
        await f.store.commit(plan: plan, decision: .importAsNew)
        #expect(f.store.isImporting == false)
    }

    @Test func `commit clears is importing on error`() async {
        let f = Self.makeStore()
        let plan = Self.makePlan()
        f.importer.commitImportError = .persistenceFailed(reason: "x")
        await f.store.commit(plan: plan, decision: .importAsNew)
        #expect(f.store.currentError != nil)
        #expect(f.store.isImporting == false)
    }

    // MARK: - dismissImportUI

    @Test func `dismiss import UI clears error importer and duplicate prompt`() {
        let f = Self.makeStore()
        f.store.isFileImporterPresented = true
        f.store.duplicatePrompt = LibraryStore.DuplicatePrompt(
            plan: Self.makePlan(),
            existing: Self.makeItem(),
        )
        f.store.currentError = .domain(.persistenceFailed(reason: "x"))
        f.store.dismissImportUI()
        #expect(f.store.isFileImporterPresented == false)
        #expect(f.store.duplicatePrompt == nil)
        #expect(f.store.currentError == nil)
    }
}
