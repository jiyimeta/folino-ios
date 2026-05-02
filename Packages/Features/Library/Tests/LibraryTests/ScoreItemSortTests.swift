import Domain
import Foundation
@testable import Library
import Testing

@Suite struct ScoreItemSortTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(
        title: String,
        composer: String?,
        addedOffset: TimeInterval,
        lastOpenedOffset: TimeInterval?
    ) -> ScoreItem {
        ScoreItem(
            title: title, composer: composer, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base.addingTimeInterval(addedOffset),
            lastOpenedAt: lastOpenedOffset.map { base.addingTimeInterval($0) },
            tagIDs: [], isFavorite: false
        )
    }

    @Test func dateAddedDescOrdersNewestFirst() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "A", composer: nil, addedOffset: 100, lastOpenedOffset: nil),
            Self.makeItem(title: "B", composer: nil, addedOffset: 300, lastOpenedOffset: nil),
            Self.makeItem(title: "C", composer: nil, addedOffset: 200, lastOpenedOffset: nil),
        ]
        let sorted = ScoreItemSort.dateAddedDesc.apply(to: items)
        #expect(sorted.map(\.title) == ["B", "C", "A"])
    }

    @Test func titleAscIsLocaleAwareAndDiacriticInsensitive() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "Étude", composer: nil, addedOffset: 0, lastOpenedOffset: nil),
            Self.makeItem(title: "Adagio", composer: nil, addedOffset: 0, lastOpenedOffset: nil),
            Self.makeItem(title: "etude", composer: nil, addedOffset: 0, lastOpenedOffset: nil),
            Self.makeItem(title: "Bagatelle", composer: nil, addedOffset: 0, lastOpenedOffset: nil),
        ]
        let sorted = ScoreItemSort.titleAsc.apply(to: items)
        #expect(sorted.map(\.title) == ["Adagio", "Bagatelle", "etude", "Étude"]
            || sorted.map(\.title) == ["Adagio", "Bagatelle", "Étude", "etude"])
    }

    @Test func composerAscPlacesNilAtEnd() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "A", composer: "Mozart", addedOffset: 0, lastOpenedOffset: nil),
            Self.makeItem(title: "B", composer: nil, addedOffset: 0, lastOpenedOffset: nil),
            Self.makeItem(title: "C", composer: "Beethoven", addedOffset: 0, lastOpenedOffset: nil),
        ]
        let sorted = ScoreItemSort.composerAsc.apply(to: items)
        #expect(sorted.map(\.composer) == ["Beethoven", "Mozart", nil])
    }

    @Test func lastOpenedDescPlacesNilAtEnd() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "A", composer: nil, addedOffset: 0, lastOpenedOffset: 100),
            Self.makeItem(title: "B", composer: nil, addedOffset: 0, lastOpenedOffset: nil),
            Self.makeItem(title: "C", composer: nil, addedOffset: 0, lastOpenedOffset: 300),
        ]
        let sorted = ScoreItemSort.lastOpenedDesc.apply(to: items)
        #expect(sorted.map(\.title) == ["C", "A", "B"])
    }
}
