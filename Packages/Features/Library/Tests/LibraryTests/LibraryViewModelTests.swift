import Domain
import Foundation
@testable import Library
import Testing

@Suite @MainActor
struct LibraryViewModelTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(title: String = "A", isFavorite: Bool = false) -> ScoreItem {
        ScoreItem(
            title: title, composer: nil, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base, lastOpenedAt: nil, tagIDs: [], isFavorite: isFavorite
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
            repository: repo, importer: importer, gateway: gateway, shareService: share
        )
        return VMFixture(vm: vm, repo: repo, importer: importer, gateway: gateway, share: share)
    }

    @Test func toggleFavoriteFlipsAndSaves() async {
        let original = Self.makeItem(isFavorite: false)
        let f = Self.makeVM(scoreItems: [original])
        await f.vm.toggleFavorite(original)
        #expect(f.repo.savedScoreItems.last?.isFavorite == true)
        #expect(f.repo.scoreItems.first?.isFavorite == true)
    }

    @Test func deleteCallsRepository() async {
        let item = Self.makeItem()
        let f = Self.makeVM(scoreItems: [item])
        await f.vm.delete(item)
        #expect(f.repo.deletedScoreItemIDs == [item.id])
        #expect(f.repo.scoreItems.isEmpty)
    }

    @Test func setTagIDsResyncsAndSaves() async {
        let item = Self.makeItem()
        let f = Self.makeVM(scoreItems: [item])
        let tagID = TagID()
        await f.vm.setTagIDs([tagID], on: item)
        #expect(f.repo.savedScoreItems.last?.tagIDs == [tagID])
    }

    @Test func saveSurfacesPersistenceErrorOnAlert() async {
        let item = Self.makeItem()
        let f = Self.makeVM(scoreItems: [item])
        f.repo.saveScoreItemError = .persistenceFailed(reason: "disk full")
        await f.vm.toggleFavorite(item)
        #expect(f.vm.errorAlertMessage == "There was a problem saving the score. Check available storage.")
    }

    @Test func deleteSurfacesPersistenceErrorOnAlert() async {
        let item = Self.makeItem()
        let f = Self.makeVM(scoreItems: [item])
        f.repo.deleteScoreItemError = .persistenceFailed(reason: "io error")
        await f.vm.delete(item)
        #expect(f.vm.errorAlertMessage == "There was a problem saving the score. Check available storage.")
    }

    @Test func createPlaylistTrimmedNonEmptyPersists() async {
        let f = Self.makeVM()
        await f.vm.createPlaylist(name: "  Recital  ")
        #expect(f.repo.savedPlaylists.count == 1)
        #expect(f.repo.savedPlaylists.first?.name == "Recital")
        #expect(f.repo.savedPlaylists.first?.orderedScoreItemIDs.isEmpty == true)
    }

    @Test func createPlaylistEmptyNameNoOp() async {
        let f = Self.makeVM()
        await f.vm.createPlaylist(name: "   ")
        #expect(f.repo.savedPlaylists.isEmpty)
    }

    @Test func createTagTrimmedNonEmptyPersistsWithDefaultColor() async {
        let f = Self.makeVM()
        await f.vm.createTag(name: "  Practice  ")
        #expect(f.repo.savedTags.count == 1)
        #expect(f.repo.savedTags.first?.name == "Practice")
        #expect(f.repo.savedTags.first?.colorHex == "#5856D6")
    }

    @Test func createTagEmptyNameNoOp() async {
        let f = Self.makeVM()
        await f.vm.createTag(name: "")
        #expect(f.repo.savedTags.isEmpty)
    }

    @Test func deletePlaylistCallsRepository() async {
        let f = Self.makeVM()
        let playlist = Playlist(name: "P", orderedScoreItemIDs: [], createdAt: Self.base)
        f.repo.playlists = [playlist]
        await f.vm.deletePlaylist(playlist)
        #expect(f.repo.deletedPlaylistIDs == [playlist.id])
        #expect(f.repo.playlists.isEmpty)
        #expect(f.vm.errorAlertMessage == nil)
    }

    @Test func deletePlaylistSurfacesPersistenceErrorOnAlert() async {
        let f = Self.makeVM()
        let playlist = Playlist(name: "P", orderedScoreItemIDs: [], createdAt: Self.base)
        f.repo.playlists = [playlist]
        f.repo.deletePlaylistError = .persistenceFailed(reason: "io error")
        await f.vm.deletePlaylist(playlist)
        #expect(f.vm.errorAlertMessage == "There was a problem saving the score. Check available storage.")
    }

    @Test func deleteTagCallsRepository() async {
        let f = Self.makeVM()
        let tag = Tag(name: "T", colorHex: "#5856D6")
        f.repo.tags = [tag]
        await f.vm.deleteTag(tag)
        #expect(f.repo.deletedTagIDs == [tag.id])
        #expect(f.repo.tags.isEmpty)
        #expect(f.vm.errorAlertMessage == nil)
    }

    @Test func deleteTagSurfacesPersistenceErrorOnAlert() async {
        let f = Self.makeVM()
        let tag = Tag(name: "T", colorHex: "#5856D6")
        f.repo.tags = [tag]
        f.repo.deleteTagError = .persistenceFailed(reason: "io error")
        await f.vm.deleteTag(tag)
        #expect(f.vm.errorAlertMessage == "There was a problem saving the score. Check available storage.")
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
                defaultTempoBpm: 120, primaryKey: nil
            ),
            contentHash: "hash",
            sizeBytes: 100,
            duplicates: duplicates
        )
    }

    @Test func happyPathImportPushesPendingOpen() async {
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
        #expect(f.vm.errorAlertMessage == nil)
    }

    @Test func duplicateStagesPromptInsteadOfCommitting() async {
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
    @Test func commitOpenExistingReturnsExistingItem() async {
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

    @Test func commitImportAsNewProducesNewItem() async {
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
    @Test func unsupportedFormatErrorMessage() async {
        let f = Self.makeVM()
        f.importer.prepareImportErrors = [.unsupportedFormat("xyz")]
        await f.vm.startImport(from: URL(filePath: "/tmp/x.xyz"))
        #expect(f.vm.errorAlertMessage == "folino can't open this file type.")
    }

    @Test func parseErrorMessage() async {
        let f = Self.makeVM()
        f.importer.prepareImportErrors = [.scoreParseFailed(reason: "bad bytes")]
        await f.vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.vm.errorAlertMessage == "This file looks corrupted or isn't a valid score.")
    }

    @Test func persistenceErrorMessage() async {
        let f = Self.makeVM()
        f.importer.preparedPlans = [Self.makePlan()]
        f.importer.commitImportError = .persistenceFailed(reason: "disk full")
        await f.vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.vm.errorAlertMessage == "There was a problem saving the score. Check available storage.")
    }
}

extension LibraryViewModelTests {
    @Test func isImportingStartsFalse() {
        let f = Self.makeVM()
        #expect(f.vm.isImporting == false)
    }

    @Test func startImportClearsIsImportingOnSuccess() async {
        let f = Self.makeVM()
        f.importer.preparedPlans = [Self.makePlan()]
        let imported = Self.makeItem(title: "Imported")
        f.importer.commitFactory = { _, _ in imported }
        await f.vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.vm.isImporting == false)
    }

    @Test func startImportClearsIsImportingOnDuplicate() async {
        let f = Self.makeVM()
        let existing = Self.makeItem(title: "Existing")
        f.importer.preparedPlans = [Self.makePlan(duplicates: [existing])]
        await f.vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.vm.duplicatePrompt != nil)
        #expect(f.vm.isImporting == false)
    }

    @Test func startImportClearsIsImportingOnPrepareError() async {
        let f = Self.makeVM()
        f.importer.prepareImportErrors = [.scoreParseFailed(reason: "bad")]
        await f.vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.vm.errorAlertMessage != nil)
        #expect(f.vm.isImporting == false)
    }

    @Test func commitClearsIsImportingOnSuccess() async {
        let f = Self.makeVM()
        let plan = Self.makePlan()
        let item = Self.makeItem(title: "X")
        f.importer.commitFactory = { _, _ in item }
        await f.vm.commit(plan: plan, decision: .importAsNew)
        #expect(f.vm.isImporting == false)
    }

    @Test func commitClearsIsImportingOnError() async {
        let f = Self.makeVM()
        let plan = Self.makePlan()
        f.importer.commitImportError = .persistenceFailed(reason: "x")
        await f.vm.commit(plan: plan, decision: .importAsNew)
        #expect(f.vm.errorAlertMessage != nil)
        #expect(f.vm.isImporting == false)
    }
}
