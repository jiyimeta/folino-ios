import Domain
import Foundation
import Testing

struct RecentlyUsedSortTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func item(
        id: ScoreItemID = ScoreItemID(),
        lastOpenedOffset: TimeInterval?,
        tagIDs: Set<TagID> = [],
    ) -> ScoreOpenInfo {
        ScoreOpenInfo(
            id: id,
            lastOpenedAt: lastOpenedOffset.map { base.addingTimeInterval($0) },
            tagIDs: tagIDs,
        )
    }

    // MARK: - playlistsByRecentlyUsed

    @Test func `playlists order by max last opened of contained items`() {
        let a = Self.item(lastOpenedOffset: 100)
        let b = Self.item(lastOpenedOffset: 300)
        let c = Self.item(lastOpenedOffset: 200)
        let p1 = Playlist(name: "P1", orderedScoreItemIDs: [a.id, b.id], createdAt: Self.base)
        let p2 = Playlist(name: "P2", orderedScoreItemIDs: [c.id], createdAt: Self.base)
        let result = playlistsByRecentlyUsed(
            [p1, p2], openInfo: [a, b, c], limit: 10,
        )
        #expect(result.map(\.name) == ["P1", "P2"]) // P1 reaches 300 (b), P2 only 200 (c)
    }

    @Test func `empty playlist falls back to created at`() {
        let recent = Self.item(lastOpenedOffset: 100)
        let withItem = Playlist(
            name: "WithItem",
            orderedScoreItemIDs: [recent.id],
            createdAt: Self.base.addingTimeInterval(-10000),
        )
        let empty = Playlist(
            name: "Empty",
            orderedScoreItemIDs: [],
            createdAt: Self.base.addingTimeInterval(10000),
        )
        let result = playlistsByRecentlyUsed(
            [withItem, empty], openInfo: [recent], limit: 10,
        )
        // Empty's createdAt (base+10_000) > WithItem's max (base+100)
        #expect(result.map(\.name) == ["Empty", "WithItem"])
    }

    @Test func `playlist missing item I ds treated as absent`() {
        let live = Self.item(lastOpenedOffset: 100)
        let stale = Playlist(
            name: "Stale",
            orderedScoreItemIDs: [ScoreItemID(), ScoreItemID()],
            createdAt: Self.base.addingTimeInterval(50),
        )
        let kept = Playlist(
            name: "Kept",
            orderedScoreItemIDs: [live.id],
            createdAt: Self.base,
        )
        let result = playlistsByRecentlyUsed(
            [stale, kept], openInfo: [live], limit: 10,
        )
        #expect(result.map(\.name) == ["Kept", "Stale"]) // Kept 100 vs Stale 50 (createdAt fallback)
    }

    @Test func `playlist limit truncates`() {
        let recent = Self.item(lastOpenedOffset: 100)
        let p1 = Playlist(name: "P1", orderedScoreItemIDs: [recent.id], createdAt: Self.base)
        let p2 = Playlist(name: "P2", orderedScoreItemIDs: [recent.id], createdAt: Self.base.addingTimeInterval(50))
        let p3 = Playlist(name: "P3", orderedScoreItemIDs: [recent.id], createdAt: Self.base.addingTimeInterval(25))
        let result = playlistsByRecentlyUsed([p1, p2, p3], openInfo: [recent], limit: 2)
        #expect(result.count == 2)
    }

    // MARK: - tagsByRecentlyUsed

    @Test func `tags order by max last opened of tagged items`() {
        let t1 = Tag(name: "t1", colorHex: "#000")
        let t2 = Tag(name: "t2", colorHex: "#000")
        let i1 = Self.item(lastOpenedOffset: 100, tagIDs: [t1.id])
        let i2 = Self.item(lastOpenedOffset: 300, tagIDs: [t2.id])
        let result = tagsByRecentlyUsed([t1, t2], openInfo: [i1, i2], limit: 10)
        #expect(result.map(\.name) == ["t2", "t1"])
    }

    @Test func `tag with no tagged items sinks to bottom`() {
        let active = Tag(name: "active", colorHex: "#000")
        let stale = Tag(name: "stale", colorHex: "#000")
        let item = Self.item(lastOpenedOffset: 50, tagIDs: [active.id])
        let result = tagsByRecentlyUsed([stale, active], openInfo: [item], limit: 10)
        #expect(result.map(\.name) == ["active", "stale"])
    }

    @Test func `tags tiebreak by name ascending`() {
        let bare1 = Tag(name: "bbb", colorHex: "#000")
        let bare2 = Tag(name: "aaa", colorHex: "#000")
        let result = tagsByRecentlyUsed([bare1, bare2], openInfo: [], limit: 10)
        #expect(result.map(\.name) == ["aaa", "bbb"])
    }

    @Test func `tag limit truncates`() {
        let tags = (0 ..< 8).map { Tag(name: "tag\($0)", colorHex: "#000") }
        let result = tagsByRecentlyUsed(tags, openInfo: [], limit: 5)
        #expect(result.count == 5)
    }
}
