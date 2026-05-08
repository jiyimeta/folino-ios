import Domain
import Foundation
@testable import Library
import Testing

@Suite @MainActor
struct ScoreListViewModelTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(
        id: ScoreItemID = ScoreItemID(),
        title: String,
        composer: String? = nil,
        addedOffset: TimeInterval = 0,
        tagIDs: Set<TagID> = []
    ) -> ScoreItem {
        ScoreItem(
            id: id,
            title: title, composer: composer, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base.addingTimeInterval(addedOffset),
            lastOpenedAt: nil, tagIDs: tagIDs, isFavorite: false
        )
    }

    private static func makeRepo(items: [ScoreItem]) -> FakeScoreLibraryRepository {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = items
        return repo
    }

    @Test func sourceAllReturnsEverythingSorted() {
        let repo = Self.makeRepo(items: [
            Self.makeItem(title: "B", addedOffset: 100),
            Self.makeItem(title: "A", addedOffset: 200),
        ])
        let vm = ScoreListViewModel(source: .all, repository: repo)
        vm.sort = .dateAddedDesc
        #expect(vm.displayedItems.map(\.title) == ["A", "B"])
    }

    @Test func sourceTaggedFiltersByTagID() {
        let tagID = TagID()
        let repo = Self.makeRepo(items: [
            Self.makeItem(title: "A", tagIDs: [tagID]),
            Self.makeItem(title: "B", tagIDs: []),
            Self.makeItem(title: "C", tagIDs: [tagID]),
        ])
        let vm = ScoreListViewModel(source: .taggedWith(tagID), repository: repo)
        vm.sort = .titleAsc
        #expect(vm.displayedItems.map(\.title) == ["A", "C"])
    }

    @Test func sourcePlaylistPreservesOrderingByDefault() {
        let id1 = ScoreItemID()
        let id2 = ScoreItemID()
        let id3 = ScoreItemID()
        let repo = Self.makeRepo(items: [
            Self.makeItem(id: id3, title: "C"),
            Self.makeItem(id: id1, title: "A"),
            Self.makeItem(id: id2, title: "B"),
        ])
        let vm = ScoreListViewModel(
            source: .playlist(orderedIDs: [id1, id2, id3]),
            repository: repo
        )
        // Default sort for playlists is .manual; items follow orderedIDs.
        #expect(vm.displayedItems.map(\.title) == ["A", "B", "C"])
    }

    @Test func sourcePlaylistSortOverrideIgnoresManualOrder() {
        let id1 = ScoreItemID()
        let id2 = ScoreItemID()
        let repo = Self.makeRepo(items: [
            Self.makeItem(id: id1, title: "B", addedOffset: 100),
            Self.makeItem(id: id2, title: "A", addedOffset: 200),
        ])
        let vm = ScoreListViewModel(
            source: .playlist(orderedIDs: [id1, id2]),
            repository: repo
        )
        vm.selectSort(.titleAsc)
        #expect(vm.displayedItems.map(\.title) == ["A", "B"])
    }

    @Test func searchMatchesTitleAndComposerCaseAndDiacriticInsensitively() {
        let repo = Self.makeRepo(items: [
            Self.makeItem(title: "Étude Op.10", composer: "Chopin"),
            Self.makeItem(title: "Sonata", composer: "Mozart"),
            Self.makeItem(title: "Prelude", composer: "Chopin"),
        ])
        let vm = ScoreListViewModel(source: .all, repository: repo)
        vm.searchQuery = "etude"
        #expect(vm.displayedItems.map(\.title) == ["Étude Op.10"])
        vm.searchQuery = "chopin"
        let chopins = Set(vm.displayedItems.map(\.title))
        #expect(chopins == ["Étude Op.10", "Prelude"])
    }

    @Test func emptySearchQueryReturnsAll() {
        let repo = Self.makeRepo(items: [
            Self.makeItem(title: "A"),
            Self.makeItem(title: "B"),
        ])
        let vm = ScoreListViewModel(source: .all, repository: repo)
        vm.searchQuery = ""
        #expect(vm.displayedItems.count == 2)
    }

    @Test func sourceFavoritesFiltersByIsFavoriteFlag() {
        var fav = Self.makeItem(title: "Fav")
        fav.isFavorite = true
        let plain = Self.makeItem(title: "Plain")
        var fav2 = Self.makeItem(title: "Fav2")
        fav2.isFavorite = true
        let repo = Self.makeRepo(items: [plain, fav, fav2])
        let vm = ScoreListViewModel(source: .favorites, repository: repo)
        vm.sort = .titleAsc
        #expect(vm.displayedItems.map(\.title) == ["Fav", "Fav2"])
    }
}
