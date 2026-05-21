import Domain
import Foundation
import LibraryLogic
import Testing

@MainActor
struct RecentlyDeletedStoreTests {
    // MARK: - Helpers

    static func makeItem(title: String, deletedAt: Date?) -> ScoreItem {
        ScoreItem(
            title: title,
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "\(UUID().uuidString).musicxml",
            contentHash: String(repeating: "0", count: 64),
            sizeBytes: 1024,
            lengthBeats: 64,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: .distantPast,
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
            deletedAt: deletedAt,
        )
    }

    // MARK: - Tests

    @Test
    func `sorts by deleted at descending`() {
        let repo = FakeScoreLibraryRepository()
        let now = Date()
        let oldest = Self.makeItem(title: "Oldest", deletedAt: now.addingTimeInterval(-200))
        let middle = Self.makeItem(title: "Middle", deletedAt: now.addingTimeInterval(-100))
        let newest = Self.makeItem(title: "Newest", deletedAt: now.addingTimeInterval(-10))
        repo.deletedScoreItems = [oldest, newest, middle]

        let store = RecentlyDeletedStore(repository: repo)

        #expect(store.displayedItems.map(\.title) == ["Newest", "Middle", "Oldest"])
    }

    @Test
    func `items missing deleted at go to bottom`() {
        let repo = FakeScoreLibraryRepository()
        let now = Date()
        let withDate = Self.makeItem(title: "WithDate", deletedAt: now.addingTimeInterval(-50))
        let noDate = Self.makeItem(title: "NoDate", deletedAt: nil)
        repo.deletedScoreItems = [noDate, withDate]

        let store = RecentlyDeletedStore(repository: repo)

        #expect(store.displayedItems.map(\.title) == ["WithDate", "NoDate"])
    }

    @Test
    func `empty repository produces empty displayed items`() {
        let repo = FakeScoreLibraryRepository()
        repo.deletedScoreItems = []

        let store = RecentlyDeletedStore(repository: repo)

        #expect(store.displayedItems.isEmpty)
    }
}
