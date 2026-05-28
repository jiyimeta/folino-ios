import Domain
import Foundation
@testable import Library
import Testing

@MainActor
struct LibraryViewModelTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(title: String = "A", isFavorite: Bool = false) -> ScoreItem {
        ScoreItem(
            title: title, composer: nil, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base, lastOpenedAt: nil, tagIDs: [], isFavorite: isFavorite,
        )
    }

    private struct VMFixture {
        let vm: LibraryViewModel
        let repo: FakeScoreLibraryRepository
        let importer: FakeScoreFileImporter
        let gateway: FakeScoreFileGateway
        let share: FakeScoreShareService
    }

    private static func makeVM(scoreItems: [ScoreItem] = []) -> VMFixture {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = scoreItems
        let importer = FakeScoreFileImporter()
        let gateway = FakeScoreFileGateway()
        let share = FakeScoreShareService()
        let vm = LibraryViewModel(
            repository: repo, importer: importer, gateway: gateway, shareService: share,
        )
        return VMFixture(vm: vm, repo: repo, importer: importer, gateway: gateway, share: share)
    }

    @Test func `toggle favorite flips and saves`() async {
        let original = Self.makeItem(isFavorite: false)
        let f = Self.makeVM(scoreItems: [original])
        await f.vm.toggleFavorite(original)
        #expect(f.repo.savedScoreItems.last?.isFavorite == true)
        #expect(f.repo.scoreItems.first?.isFavorite == true)
    }

    @Test func `delete soft deletes via repository`() async {
        let item = Self.makeItem()
        let f = Self.makeVM(scoreItems: [item])
        await f.vm.delete(item)
        // The default `deleteScoreItem` path now soft-deletes; both buckets are populated by the fake.
        #expect(f.repo.deletedScoreItemIDs == [item.id])
        #expect(f.repo.softDeletedScoreItemIDs == [item.id])
        #expect(f.repo.permanentlyDeletedScoreItemIDs.isEmpty)
        #expect(f.repo.scoreItems.isEmpty)
        #expect(f.repo.deletedScoreItems.count == 1)
    }

    @Test func `restore calls repository restore`() async throws {
        let item = Self.makeItem()
        let f = Self.makeVM(scoreItems: [item])
        await f.vm.delete(item)
        let trashed = try #require(f.repo.deletedScoreItems.first)
        await f.vm.restore(trashed)
        #expect(f.repo.restoredScoreItemIDs == [item.id])
        #expect(f.repo.scoreItems.count == 1)
        #expect(f.repo.deletedScoreItems.isEmpty)
    }

    @Test func `permanently delete calls repository permanently delete`() async throws {
        let item = Self.makeItem()
        let f = Self.makeVM(scoreItems: [item])
        await f.vm.delete(item)
        let trashed = try #require(f.repo.deletedScoreItems.first)
        await f.vm.permanentlyDelete(trashed)
        #expect(f.repo.permanentlyDeletedScoreItemIDs == [item.id])
        #expect(f.repo.scoreItems.isEmpty)
        #expect(f.repo.deletedScoreItems.isEmpty)
    }

    @Test func `set tag I ds resyncs and saves`() async {
        let item = Self.makeItem()
        let f = Self.makeVM(scoreItems: [item])
        let tagID = TagID()
        await f.vm.setTagIDs([tagID], on: item)
        #expect(f.repo.savedScoreItems.last?.tagIDs == [tagID])
    }

    @Test func `save surfaces persistence error on alert`() async {
        let item = Self.makeItem()
        let f = Self.makeVM(scoreItems: [item])
        f.repo.saveScoreItemError = .persistenceFailed(reason: "disk full")
        await f.vm.toggleFavorite(item)
        if case .persistenceFailed = f.vm.currentError as? DomainError {} else {
            Issue.record("expected .persistenceFailed")
        }
    }

    @Test func `delete surfaces persistence error on alert`() async {
        let item = Self.makeItem()
        let f = Self.makeVM(scoreItems: [item])
        f.repo.deleteScoreItemError = .persistenceFailed(reason: "io error")
        await f.vm.delete(item)
        if case .persistenceFailed = f.vm.currentError as? DomainError {} else {
            Issue.record("expected .persistenceFailed")
        }
    }

    @Test func `create playlist trimmed non empty persists`() async {
        let f = Self.makeVM()
        await f.vm.createPlaylist(name: "  Recital  ")
        #expect(f.repo.savedPlaylists.count == 1)
        #expect(f.repo.savedPlaylists.first?.name == "Recital")
        #expect(f.repo.savedPlaylists.first?.orderedScoreItemIDs.isEmpty == true)
    }

    @Test func `create playlist empty name no op`() async {
        let f = Self.makeVM()
        await f.vm.createPlaylist(name: "   ")
        #expect(f.repo.savedPlaylists.isEmpty)
    }

    @Test func `create tag trimmed non empty persists with default color`() async {
        let f = Self.makeVM()
        await f.vm.createTag(name: "  Practice  ")
        #expect(f.repo.savedTags.count == 1)
        #expect(f.repo.savedTags.first?.name == "Practice")
        #expect(f.repo.savedTags.first?.colorHex == "#5856D6")
    }

    @Test func `create tag empty name no op`() async {
        let f = Self.makeVM()
        await f.vm.createTag(name: "")
        #expect(f.repo.savedTags.isEmpty)
    }

    @Test func `delete playlist calls repository`() async {
        let f = Self.makeVM()
        let playlist = Playlist(name: "P", orderedScoreItemIDs: [], createdAt: Self.base)
        f.repo.playlists = [playlist]
        await f.vm.deletePlaylist(playlist)
        #expect(f.repo.deletedPlaylistIDs == [playlist.id])
        #expect(f.repo.playlists.isEmpty)
        #expect(f.vm.currentError == nil)
    }

    @Test func `delete playlist surfaces persistence error on alert`() async {
        let f = Self.makeVM()
        let playlist = Playlist(name: "P", orderedScoreItemIDs: [], createdAt: Self.base)
        f.repo.playlists = [playlist]
        f.repo.deletePlaylistError = .persistenceFailed(reason: "io error")
        await f.vm.deletePlaylist(playlist)
        if case .persistenceFailed = f.vm.currentError as? DomainError {} else {
            Issue.record("expected .persistenceFailed")
        }
    }

    @Test func `delete tag calls repository`() async {
        let f = Self.makeVM()
        let tag = Tag(name: "T", colorHex: "#5856D6")
        f.repo.tags = [tag]
        await f.vm.deleteTag(tag)
        #expect(f.repo.deletedTagIDs == [tag.id])
        #expect(f.repo.tags.isEmpty)
        #expect(f.vm.currentError == nil)
    }

    @Test func `delete tag surfaces persistence error on alert`() async {
        let f = Self.makeVM()
        let tag = Tag(name: "T", colorHex: "#5856D6")
        f.repo.tags = [tag]
        f.repo.deleteTagError = .persistenceFailed(reason: "io error")
        await f.vm.deleteTag(tag)
        if case .persistenceFailed = f.vm.currentError as? DomainError {} else {
            Issue.record("expected .persistenceFailed")
        }
    }
}

extension LibraryViewModelTests {
    fileprivate static func makePlan(duplicates: [ScoreItem] = []) -> ImportPlan {
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
        let f = Self.makeVM()
        let plan = Self.makePlan()
        f.importer.preparedPlans = [plan]
        let imported = Self.makeItem(title: "Imported")
        f.importer.commitFactory = { _, _ in imported }

        await f.vm.startImport(from: plan.sourceURL)
        #expect(f.importer.committed.count == 1)
        if case .importAsNew = f.importer.committed.first?.decision {} else {
            Issue.record("expected .importAsNew")
        }
        #expect(f.vm.pendingScoreToOpen?.id == imported.id)
        #expect(f.vm.duplicatePrompt == nil)
        #expect(f.vm.currentError == nil)
    }

    @Test func `duplicate stages prompt instead of committing`() async {
        let f = Self.makeVM()
        let existing = Self.makeItem(title: "Existing")
        let plan = Self.makePlan(duplicates: [existing])
        f.importer.preparedPlans = [plan]
        f.importer.commitFactory = { _, _ in existing }

        await f.vm.startImport(from: plan.sourceURL)
        #expect(f.importer.committed.isEmpty)
        #expect(f.vm.duplicatePrompt?.existing.id == existing.id)
        #expect(f.vm.pendingScoreToOpen == nil)
    }
}

extension LibraryViewModelTests {
    @Test func `commit open existing returns existing item`() async {
        let f = Self.makeVM()
        let existing = Self.makeItem(title: "Existing")
        let plan = Self.makePlan(duplicates: [existing])
        let differentItem = Self.makeItem(title: "DifferentItem")
        f.importer.commitFactory = { _, decision in
            if case .openExisting = decision { return existing }
            return differentItem
        }

        await f.vm.commit(plan: plan, decision: .openExisting(existing.id))
        #expect(f.vm.pendingScoreToOpen?.id == existing.id)
    }

    @Test func `commit import as new produces new item`() async {
        let f = Self.makeVM()
        let existing = Self.makeItem(title: "Existing")
        let plan = Self.makePlan(duplicates: [existing])
        let new = Self.makeItem(title: "New")
        f.importer.commitFactory = { _, decision in
            if case .importAsNew = decision { return new }
            return existing
        }

        await f.vm.commit(plan: plan, decision: .importAsNew)
        #expect(f.vm.pendingScoreToOpen?.id == new.id)
    }
}

extension LibraryViewModelTests {
    @Test func `unsupported format error message`() async {
        let f = Self.makeVM()
        f.importer.prepareImportErrors = [.unsupportedFormat("xyz")]
        await f.vm.startImport(from: URL(filePath: "/tmp/x.xyz"))
        if case .unsupportedFormat = f.vm.currentError as? DomainError {} else {
            Issue.record("expected .unsupportedFormat")
        }
    }

    @Test func `parse error message`() async {
        let f = Self.makeVM()
        f.importer.prepareImportErrors = [.scoreParseFailed(reason: "bad bytes")]
        await f.vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        if case .scoreParseFailed = f.vm.currentError as? DomainError {} else {
            Issue.record("expected .scoreParseFailed")
        }
    }

    @Test func `persistence error message`() async {
        let f = Self.makeVM()
        f.importer.preparedPlans = [Self.makePlan()]
        f.importer.commitImportError = .persistenceFailed(reason: "disk full")
        await f.vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        if case .persistenceFailed = f.vm.currentError as? DomainError {} else {
            Issue.record("expected .persistenceFailed")
        }
    }
}

extension LibraryViewModelTests {
    @Test func `is importing starts false`() {
        let f = Self.makeVM()
        #expect(f.vm.isImporting == false)
    }

    @Test func `start import clears is importing on success`() async {
        let f = Self.makeVM()
        f.importer.preparedPlans = [Self.makePlan()]
        let imported = Self.makeItem(title: "Imported")
        f.importer.commitFactory = { _, _ in imported }
        await f.vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.vm.isImporting == false)
    }

    @Test func `start import clears is importing on duplicate`() async {
        let f = Self.makeVM()
        let existing = Self.makeItem(title: "Existing")
        f.importer.preparedPlans = [Self.makePlan(duplicates: [existing])]
        await f.vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.vm.duplicatePrompt != nil)
        #expect(f.vm.isImporting == false)
    }

    @Test func `start import clears is importing on prepare error`() async {
        let f = Self.makeVM()
        f.importer.prepareImportErrors = [.scoreParseFailed(reason: "bad")]
        await f.vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.vm.currentError != nil)
        #expect(f.vm.isImporting == false)
    }

    @Test func `commit clears is importing on success`() async {
        let f = Self.makeVM()
        let plan = Self.makePlan()
        let item = Self.makeItem(title: "X")
        f.importer.commitFactory = { _, _ in item }
        await f.vm.commit(plan: plan, decision: .importAsNew)
        #expect(f.vm.isImporting == false)
    }

    @Test func `commit clears is importing on error`() async {
        let f = Self.makeVM()
        let plan = Self.makePlan()
        f.importer.commitImportError = .persistenceFailed(reason: "x")
        await f.vm.commit(plan: plan, decision: .importAsNew)
        #expect(f.vm.currentError != nil)
        #expect(f.vm.isImporting == false)
    }
}
