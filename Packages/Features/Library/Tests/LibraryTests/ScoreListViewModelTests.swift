import Domain
import Foundation
@testable import Library
import Testing

@MainActor
struct ScoreListViewModelTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(
        id: ScoreItemID = ScoreItemID(),
        title: String,
        composer: String? = nil,
        addedOffset: TimeInterval = 0,
        tagIDs: Set<TagID> = [],
    ) -> ScoreItem {
        ScoreItem(
            id: id,
            title: title, composer: composer, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base.addingTimeInterval(addedOffset),
            lastOpenedAt: nil, tagIDs: tagIDs, isFavorite: false,
        )
    }

    private static func makeRepo(items: [ScoreItem]) -> FakeScoreLibraryRepository {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = items
        return repo
    }

    /// A clean, isolated `UserDefaults` domain so persistence assertions don't leak into `.standard` or each other.
    private static func makeDefaults(_ suite: String) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func `sort defaults to date added desc when nothing persisted`() throws {
        let defaults = try Self.makeDefaults("test.librarySort.default")
        let vm = ScoreListViewModel(source: .all, repository: Self.makeRepo(items: []), defaults: defaults)
        #expect(vm.sort == .dateAddedDesc)
    }

    @Test func `selected sort persists across view model recreation`() throws {
        let defaults = try Self.makeDefaults("test.librarySort.persist")
        let repo = Self.makeRepo(items: [])
        let vm1 = ScoreListViewModel(source: .all, repository: repo, defaults: defaults)
        vm1.selectSort(.titleAsc)
        // Simulate an app relaunch: a fresh view model over the same defaults must recover the picked sort.
        let vm2 = ScoreListViewModel(source: .all, repository: repo, defaults: defaults)
        #expect(vm2.sort == .titleAsc)
    }

    @Test func `playlist sort selection does not persist to the global library sort`() throws {
        let defaults = try Self.makeDefaults("test.librarySort.playlist")
        let id1 = ScoreItemID()
        let repo = Self.makeRepo(items: [Self.makeItem(id: id1, title: "A")])
        let playlistVM = ScoreListViewModel(
            source: .playlist(orderedIDs: [id1]), repository: repo, defaults: defaults,
        )
        playlistVM.selectSort(.titleAsc)
        // Playlists default to manual order on relaunch, so their sort pick is transient and must not leak globally.
        let libraryVM = ScoreListViewModel(source: .all, repository: repo, defaults: defaults)
        #expect(libraryVM.sort == .dateAddedDesc)
    }

    @Test func `source all returns everything sorted`() {
        let repo = Self.makeRepo(items: [
            Self.makeItem(title: "B", addedOffset: 100),
            Self.makeItem(title: "A", addedOffset: 200),
        ])
        let vm = ScoreListViewModel(source: .all, repository: repo)
        vm.sort = .dateAddedDesc
        #expect(vm.displayedItems.map(\.title) == ["A", "B"])
    }

    @Test func `source tagged filters by tag ID`() {
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

    @Test func `source playlist preserves ordering by default`() {
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
            repository: repo,
        )
        // Default sort for playlists is .manual; items follow orderedIDs.
        #expect(vm.displayedItems.map(\.title) == ["A", "B", "C"])
    }

    @Test func `source playlist sort override ignores manual order`() {
        let id1 = ScoreItemID()
        let id2 = ScoreItemID()
        let repo = Self.makeRepo(items: [
            Self.makeItem(id: id1, title: "B", addedOffset: 100),
            Self.makeItem(id: id2, title: "A", addedOffset: 200),
        ])
        let vm = ScoreListViewModel(
            source: .playlist(orderedIDs: [id1, id2]),
            repository: repo,
        )
        vm.selectSort(.titleAsc)
        #expect(vm.displayedItems.map(\.title) == ["A", "B"])
    }

    @Test func `search matches title and composer case and diacritic insensitively`() {
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

    @Test func `empty search query returns all`() {
        let repo = Self.makeRepo(items: [
            Self.makeItem(title: "A"),
            Self.makeItem(title: "B"),
        ])
        let vm = ScoreListViewModel(source: .all, repository: repo)
        vm.searchQuery = ""
        #expect(vm.displayedItems.count == 2)
    }

    @Test func `source favorites filters by is favorite flag`() {
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
