import Domain
import Foundation
import LibraryLogic
import Testing

@MainActor
struct ScoreListStoreTests {
    // MARK: - Helpers

    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(
        title: String,
        composer: String? = nil,
        tagIDs: Set<TagID> = [],
        isFavorite: Bool = false,
        addedOffset: TimeInterval = 0,
    ) -> ScoreItem {
        ScoreItem(
            title: title,
            composer: composer,
            instrumentationSummary: nil,
            localFileName: "\(title).mscx",
            contentHash: title,
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: base.addingTimeInterval(addedOffset),
            lastOpenedAt: nil,
            tagIDs: tagIDs,
            isFavorite: isFavorite,
        )
    }

    // MARK: - Source scoping: .all

    @Test func `all source returns all items`() {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [
            Self.makeItem(title: "A"),
            Self.makeItem(title: "B"),
            Self.makeItem(title: "C"),
        ]
        let store = ScoreListStore(source: .all, repository: repo)
        #expect(store.displayedItems.count == 3)
    }

    // MARK: - Source scoping: .favorites

    @Test func `favorites source returns only favorite items`() {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [
            Self.makeItem(title: "Fav1", isFavorite: true),
            Self.makeItem(title: "NotFav"),
            Self.makeItem(title: "Fav2", isFavorite: true),
        ]
        let store = ScoreListStore(source: .favorites, repository: repo)
        #expect(store.displayedItems.map(\.title).sorted() == ["Fav1", "Fav2"])
    }

    @Test func `favorites source returns empty when no favorites`() {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [Self.makeItem(title: "A"), Self.makeItem(title: "B")]
        let store = ScoreListStore(source: .favorites, repository: repo)
        #expect(store.displayedItems.isEmpty)
    }

    // MARK: - Source scoping: .taggedWith

    @Test func `taggedWith source returns only items with matching tag`() {
        let tagID = TagID()
        let otherID = TagID()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [
            Self.makeItem(title: "Tagged", tagIDs: [tagID]),
            Self.makeItem(title: "Other", tagIDs: [otherID]),
            Self.makeItem(title: "Both", tagIDs: [tagID, otherID]),
            Self.makeItem(title: "None"),
        ]
        let store = ScoreListStore(source: .taggedWith(tagID), repository: repo)
        #expect(store.displayedItems.map(\.title).sorted() == ["Both", "Tagged"])
    }

    // MARK: - Source scoping: .playlist

    @Test func `playlist source preserves manual order`() {
        let repo = FakeScoreLibraryRepository()
        let items = [
            Self.makeItem(title: "First"),
            Self.makeItem(title: "Second"),
            Self.makeItem(title: "Third"),
        ]
        repo.scoreItems = items
        // Playlist order is reversed from the items array
        let orderedIDs = items.reversed().map(\.id)
        let store = ScoreListStore(source: .playlist(orderedIDs: orderedIDs), repository: repo)
        // isManualOrderActive is true initially for playlist
        #expect(store.displayedItems.map(\.title) == ["Third", "Second", "First"])
    }

    @Test func `playlist source skips IDs not present in repository`() {
        let repo = FakeScoreLibraryRepository()
        let item = Self.makeItem(title: "Exists")
        repo.scoreItems = [item]
        let missingID = ScoreItemID()
        let store = ScoreListStore(source: .playlist(orderedIDs: [missingID, item.id]), repository: repo)
        #expect(store.displayedItems.map(\.title) == ["Exists"])
    }

    // MARK: - isManualOrderActive

    @Test func `isManualOrderActive is true for playlist source initially`() {
        let repo = FakeScoreLibraryRepository()
        let store = ScoreListStore(source: .playlist(orderedIDs: []), repository: repo)
        #expect(store.isManualOrderActive == true)
    }

    @Test func `isManualOrderActive is false for non-playlist sources`() {
        let repo = FakeScoreLibraryRepository()
        #expect(ScoreListStore(source: .all, repository: repo).isManualOrderActive == false)
        #expect(ScoreListStore(source: .favorites, repository: repo).isManualOrderActive == false)
        #expect(ScoreListStore(source: .taggedWith(TagID()), repository: repo).isManualOrderActive == false)
    }

    // MARK: - selectSort

    @Test func `selectSort updates sort and clears manual order`() {
        let repo = FakeScoreLibraryRepository()
        let store = ScoreListStore(source: .playlist(orderedIDs: []), repository: repo)
        #expect(store.isManualOrderActive == true)
        store.selectSort(.titleAsc)
        #expect(store.sort == .titleAsc)
        #expect(store.isManualOrderActive == false)
    }

    @Test func `selectSort on non-playlist source updates sort`() {
        let repo = FakeScoreLibraryRepository()
        let store = ScoreListStore(source: .all, repository: repo)
        store.selectSort(.composerAsc)
        #expect(store.sort == .composerAsc)
    }

    // MARK: - selectManualOrder

    @Test func `selectManualOrder restores manual order for playlist`() {
        let repo = FakeScoreLibraryRepository()
        let store = ScoreListStore(source: .playlist(orderedIDs: []), repository: repo)
        store.selectSort(.titleAsc)
        #expect(store.isManualOrderActive == false)
        store.selectManualOrder()
        #expect(store.isManualOrderActive == true)
    }

    @Test func `selectManualOrder is no-op for non-playlist source`() {
        let repo = FakeScoreLibraryRepository()
        let store = ScoreListStore(source: .all, repository: repo)
        store.selectManualOrder()
        #expect(store.isManualOrderActive == false)
    }

    // MARK: - Search filtering

    @Test func `empty searchQuery returns all items`() {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [
            Self.makeItem(title: "Alpha"),
            Self.makeItem(title: "Beta"),
        ]
        let store = ScoreListStore(source: .all, repository: repo)
        store.searchQuery = ""
        #expect(store.displayedItems.count == 2)
    }

    @Test func `whitespace-only searchQuery returns all items`() {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [Self.makeItem(title: "A"), Self.makeItem(title: "B")]
        let store = ScoreListStore(source: .all, repository: repo)
        store.searchQuery = "   "
        #expect(store.displayedItems.count == 2)
    }

    @Test func `search filters by title case-insensitively`() {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [
            Self.makeItem(title: "Moonlight Sonata"),
            Self.makeItem(title: "Fur Elise"),
        ]
        let store = ScoreListStore(source: .all, repository: repo)
        store.searchQuery = "moonlight"
        #expect(store.displayedItems.map(\.title) == ["Moonlight Sonata"])
    }

    @Test func `search filters by composer case-insensitively`() {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [
            Self.makeItem(title: "Symphony No. 5", composer: "Beethoven"),
            Self.makeItem(title: "The Four Seasons", composer: "Vivaldi"),
        ]
        let store = ScoreListStore(source: .all, repository: repo)
        store.searchQuery = "beethoven"
        #expect(store.displayedItems.map(\.title) == ["Symphony No. 5"])
    }

    @Test func `search is diacritic-insensitive for title`() {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [
            Self.makeItem(title: "Étude"),
            Self.makeItem(title: "Waltz"),
        ]
        let store = ScoreListStore(source: .all, repository: repo)
        store.searchQuery = "etude"
        #expect(store.displayedItems.map(\.title) == ["Étude"])
    }

    @Test func `search is diacritic-insensitive for composer`() {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [
            Self.makeItem(title: "Gymnopédie No. 1", composer: "Satie"),
            Self.makeItem(title: "Prélude", composer: "Debüssy"),
        ]
        let store = ScoreListStore(source: .all, repository: repo)
        store.searchQuery = "debussy"
        #expect(store.displayedItems.map(\.title) == ["Prélude"])
    }

    @Test func `search returns empty when no matches`() {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [Self.makeItem(title: "Alpha"), Self.makeItem(title: "Beta")]
        let store = ScoreListStore(source: .all, repository: repo)
        store.searchQuery = "zzz"
        #expect(store.displayedItems.isEmpty)
    }

    @Test func `search matches both title and composer in same result set`() {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [
            Self.makeItem(title: "Bach Suite", composer: "Bach"),
            Self.makeItem(title: "Suite No. 2", composer: "Handel"),
            Self.makeItem(title: "Invention", composer: nil),
        ]
        let store = ScoreListStore(source: .all, repository: repo)
        store.searchQuery = "suite"
        #expect(store.displayedItems.count == 2)
    }
}
