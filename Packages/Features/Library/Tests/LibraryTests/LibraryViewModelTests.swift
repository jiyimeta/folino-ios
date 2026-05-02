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

    private static func makeVM(
        scoreItems: [ScoreItem] = []
    ) -> (LibraryViewModel, FakeScoreLibraryRepository, FakeScoreFileImporter, FakeScoreFileGateway) {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = scoreItems
        let importer = FakeScoreFileImporter()
        let gateway = FakeScoreFileGateway()
        let vm = LibraryViewModel(repository: repo, importer: importer, gateway: gateway)
        return (vm, repo, importer, gateway)
    }

    @Test func toggleFavoriteFlipsAndSaves() async {
        let original = Self.makeItem(isFavorite: false)
        let (vm, repo, _, _) = Self.makeVM(scoreItems: [original])
        await vm.toggleFavorite(original)
        #expect(repo.savedScoreItems.last?.isFavorite == true)
        #expect(repo.scoreItems.first?.isFavorite == true)
    }

    @Test func deleteCallsRepository() async {
        let item = Self.makeItem()
        let (vm, repo, _, _) = Self.makeVM(scoreItems: [item])
        await vm.delete(item)
        #expect(repo.deletedScoreItemIDs == [item.id])
        #expect(repo.scoreItems.isEmpty)
    }

    @Test func setTagIDsResyncsAndSaves() async {
        let item = Self.makeItem()
        let (vm, repo, _, _) = Self.makeVM(scoreItems: [item])
        let tagID = TagID()
        await vm.setTagIDs([tagID], on: item)
        #expect(repo.savedScoreItems.last?.tagIDs == [tagID])
    }

    @Test func saveSurfacesPersistenceErrorOnAlert() async {
        let item = Self.makeItem()
        let (vm, repo, _, _) = Self.makeVM(scoreItems: [item])
        repo.saveScoreItemError = .persistenceFailed(reason: "disk full")
        await vm.toggleFavorite(item)
        #expect(vm.errorAlertMessage == "There was a problem saving the score. Check available storage.")
    }

    @Test func deleteSurfacesPersistenceErrorOnAlert() async {
        let item = Self.makeItem()
        let (vm, repo, _, _) = Self.makeVM(scoreItems: [item])
        repo.deleteScoreItemError = .persistenceFailed(reason: "io error")
        await vm.delete(item)
        #expect(vm.errorAlertMessage == "There was a problem saving the score. Check available storage.")
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
        let (vm, _, importer, _) = Self.makeVM()
        let plan = Self.makePlan()
        importer.preparedPlans = [plan]
        let imported = Self.makeItem(title: "Imported")
        importer.commitFactory = { _, _ in imported }

        await vm.startImport(from: plan.sourceURL)
        #expect(importer.committed.count == 1)
        if case .importAsNew = importer.committed.first?.decision {} else {
            Issue.record("expected .importAsNew")
        }
        #expect(vm.pendingScoreToOpen?.id == imported.id)
        #expect(vm.duplicatePrompt == nil)
        #expect(vm.errorAlertMessage == nil)
    }

    @Test func duplicateStagesPromptInsteadOfCommitting() async {
        let (vm, _, importer, _) = Self.makeVM()
        let existing = Self.makeItem(title: "Existing")
        let plan = Self.makePlan(duplicates: [existing])
        importer.preparedPlans = [plan]
        importer.commitFactory = { _, _ in existing }

        await vm.startImport(from: plan.sourceURL)
        #expect(importer.committed.isEmpty)
        #expect(vm.duplicatePrompt?.existing.id == existing.id)
        #expect(vm.pendingScoreToOpen == nil)
    }
}

extension LibraryViewModelTests {
    @Test func commitOpenExistingReturnsExistingItem() async {
        let (vm, _, importer, _) = Self.makeVM()
        let existing = Self.makeItem(title: "Existing")
        let plan = Self.makePlan(duplicates: [existing])
        let differentItem = Self.makeItem(title: "DifferentItem")
        importer.commitFactory = { _, decision in
            if case .openExisting = decision { return existing }
            return differentItem
        }

        await vm.commit(plan: plan, decision: .openExisting(existing.id))
        #expect(vm.pendingScoreToOpen?.id == existing.id)
    }

    @Test func commitImportAsNewProducesNewItem() async {
        let (vm, _, importer, _) = Self.makeVM()
        let existing = Self.makeItem(title: "Existing")
        let plan = Self.makePlan(duplicates: [existing])
        let new = Self.makeItem(title: "New")
        importer.commitFactory = { _, decision in
            if case .importAsNew = decision { return new }
            return existing
        }

        await vm.commit(plan: plan, decision: .importAsNew)
        #expect(vm.pendingScoreToOpen?.id == new.id)
    }
}

extension LibraryViewModelTests {
    @Test func unsupportedFormatErrorMessage() async {
        let (vm, _, importer, _) = Self.makeVM()
        importer.prepareImportErrors = [.unsupportedFormat("xyz")]
        await vm.startImport(from: URL(filePath: "/tmp/x.xyz"))
        #expect(vm.errorAlertMessage == "Folino can't open this file type.")
    }

    @Test func parseErrorMessage() async {
        let (vm, _, importer, _) = Self.makeVM()
        importer.prepareImportErrors = [.scoreParseFailed(reason: "bad bytes")]
        await vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(vm.errorAlertMessage == "This file looks corrupted or isn't a valid score.")
    }

    @Test func persistenceErrorMessage() async {
        let (vm, _, importer, _) = Self.makeVM()
        importer.preparedPlans = [Self.makePlan()]
        importer.commitImportError = .persistenceFailed(reason: "disk full")
        await vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(vm.errorAlertMessage == "There was a problem saving the score. Check available storage.")
    }
}
