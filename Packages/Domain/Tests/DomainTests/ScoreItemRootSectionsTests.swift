@testable import Domain
import Foundation
import Testing

@Suite struct ScoreItemRootSectionsTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(
        title: String,
        addedAtOffset: TimeInterval,
        lastOpenedOffset: TimeInterval?,
        isFavorite: Bool = false
    ) -> ScoreItem {
        ScoreItem(
            title: title,
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "\(title).mscx",
            contentHash: title,
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: base.addingTimeInterval(addedAtOffset),
            lastOpenedAt: lastOpenedOffset.map { base.addingTimeInterval($0) },
            tagIDs: [],
            isFavorite: isFavorite
        )
    }

    @Test func mostRecentlyOpenedExcludesNilAndOrdersDesc() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "A", addedAtOffset: 0, lastOpenedOffset: 100),
            Self.makeItem(title: "B", addedAtOffset: 0, lastOpenedOffset: nil),
            Self.makeItem(title: "C", addedAtOffset: 0, lastOpenedOffset: 300),
            Self.makeItem(title: "D", addedAtOffset: 0, lastOpenedOffset: 200),
        ]
        let result = items.mostRecentlyOpened(limit: 5)
        #expect(result.map(\.title) == ["C", "D", "A"])
    }

    @Test func mostRecentlyOpenedRespectsLimit() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "A", addedAtOffset: 0, lastOpenedOffset: 100),
            Self.makeItem(title: "B", addedAtOffset: 0, lastOpenedOffset: 200),
            Self.makeItem(title: "C", addedAtOffset: 0, lastOpenedOffset: 300),
        ]
        #expect(items.mostRecentlyOpened(limit: 2).map(\.title) == ["C", "B"])
    }

    @Test func favoritesFiltersAndSortsByAddedAtDesc() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "A", addedAtOffset: 100, lastOpenedOffset: nil, isFavorite: true),
            Self.makeItem(title: "B", addedAtOffset: 200, lastOpenedOffset: nil, isFavorite: false),
            Self.makeItem(title: "C", addedAtOffset: 300, lastOpenedOffset: nil, isFavorite: true),
            Self.makeItem(title: "D", addedAtOffset: 50, lastOpenedOffset: nil, isFavorite: true),
        ]
        let result = items.favorites(limit: 5)
        #expect(result.map(\.title) == ["C", "A", "D"])
    }

    @Test func favoritesRespectsLimit() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "A", addedAtOffset: 100, lastOpenedOffset: nil, isFavorite: true),
            Self.makeItem(title: "B", addedAtOffset: 200, lastOpenedOffset: nil, isFavorite: true),
            Self.makeItem(title: "C", addedAtOffset: 300, lastOpenedOffset: nil, isFavorite: true),
        ]
        #expect(items.favorites(limit: 2).map(\.title) == ["C", "B"])
    }

    @Test func emptyInputReturnsEmpty() {
        let items: [ScoreItem] = []
        #expect(items.mostRecentlyOpened(limit: 5).isEmpty)
        #expect(items.favorites(limit: 5).isEmpty)
    }
}
