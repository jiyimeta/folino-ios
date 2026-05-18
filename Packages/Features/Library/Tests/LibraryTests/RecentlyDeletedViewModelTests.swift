import Domain
import Foundation
@testable import Library
import Testing

@MainActor
struct RecentlyDeletedViewModelTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(title: String, deletedAt: Date?) -> ScoreItem {
        ScoreItem(
            title: title, composer: nil, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base, lastOpenedAt: nil, tagIDs: [], isFavorite: false,
            deletedAt: deletedAt,
        )
    }

    @Test func `displayed items sorted by deleted at descending`() {
        let oldest = Self.makeItem(title: "Oldest", deletedAt: Self.base.addingTimeInterval(-3000))
        let middle = Self.makeItem(title: "Middle", deletedAt: Self.base.addingTimeInterval(-2000))
        let newest = Self.makeItem(title: "Newest", deletedAt: Self.base.addingTimeInterval(-1000))
        let repo = FakeScoreLibraryRepository()
        // Seed in shuffled order to make sure sort isn't accidentally an
        // identity reordering.
        repo.deletedScoreItems = [middle, oldest, newest]
        let vm = RecentlyDeletedViewModel(repository: repo)

        let titles = vm.displayedItems.map(\.title)
        #expect(titles == ["Newest", "Middle", "Oldest"])
    }

    @Test func `displayed items empty when no deleted`() {
        let repo = FakeScoreLibraryRepository()
        repo.deletedScoreItems = []
        let vm = RecentlyDeletedViewModel(repository: repo)
        #expect(vm.displayedItems.isEmpty)
    }

    @Test func `displayed items excludes live items`() {
        let live = Self.makeItem(title: "Live", deletedAt: nil)
        let trashed = Self.makeItem(title: "Trashed", deletedAt: Self.base)
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [live]
        repo.deletedScoreItems = [trashed]
        let vm = RecentlyDeletedViewModel(repository: repo)

        #expect(vm.displayedItems.map(\.title) == ["Trashed"])
    }
}
