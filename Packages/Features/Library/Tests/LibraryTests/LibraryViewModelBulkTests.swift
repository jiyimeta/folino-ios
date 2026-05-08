import Domain
import Foundation
@testable import Library
import Testing

@Suite @MainActor
struct LibraryViewModelBulkTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(title: String) -> ScoreItem {
        ScoreItem(
            title: title, composer: nil, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base, lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    private struct VMFixture {
        let vm: LibraryViewModel
        let repo: FakeScoreLibraryRepository
    }

    private static func makeVM(scoreItems: [ScoreItem] = []) -> VMFixture {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = scoreItems
        let vm = LibraryViewModel(
            repository: repo,
            importer: FakeScoreFileImporter(),
            gateway: FakeScoreFileGateway(),
            shareService: FakeScoreShareService()
        )
        return VMFixture(vm: vm, repo: repo)
    }

    // MARK: - bulkDelete

    @Test func bulkDeleteRemovesAllPassedIDs() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let c = Self.makeItem(title: "C")
        let f = Self.makeVM(scoreItems: [a, b, c])

        await f.vm.bulkDelete([a.id, c.id])

        #expect(Set(f.repo.deletedScoreItemIDs) == [a.id, c.id])
        #expect(f.repo.scoreItems.map(\.id) == [b.id])
        #expect(f.vm.errorAlertMessage == nil)
    }

    @Test func bulkDeleteEmptyIsNoOp() async {
        let f = Self.makeVM(scoreItems: [Self.makeItem(title: "A")])
        await f.vm.bulkDelete([])
        #expect(f.repo.deletedScoreItemIDs.isEmpty)
        #expect(f.vm.errorAlertMessage == nil)
    }

    @Test func bulkDeleteStopsAtFirstError() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let f = Self.makeVM(scoreItems: [a, b])
        f.repo.deleteScoreItemError = .persistenceFailed(reason: "boom")

        await f.vm.bulkDelete([a.id, b.id])

        #expect(f.repo.deletedScoreItemIDs.isEmpty) // FakeRepo throws before recording
        #expect(f.vm.errorAlertMessage != nil)
    }
}
