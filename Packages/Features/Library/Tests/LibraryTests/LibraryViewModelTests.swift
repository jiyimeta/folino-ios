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
        #expect(vm.errorAlertMessage?.contains("disk full") == true)
    }

    @Test func deleteSurfacesPersistenceErrorOnAlert() async {
        let item = Self.makeItem()
        let (vm, repo, _, _) = Self.makeVM(scoreItems: [item])
        repo.deleteScoreItemError = .persistenceFailed(reason: "io error")
        await vm.delete(item)
        #expect(vm.errorAlertMessage?.contains("io error") == true)
    }
}
