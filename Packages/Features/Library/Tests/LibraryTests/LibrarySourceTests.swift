import Domain
import Foundation
@testable import Library
import Testing

@Suite("LibrarySourceList")
struct LibrarySourceTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(title: String, favorite: Bool = false, opened: Date? = nil) -> ScoreItem {
        var made = ScoreItem(
            title: title, composer: nil, instrumentationSummary: "Piano",
            localFileName: "\(UUID().uuidString).musicxml", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Self.base, lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        made.isFavorite = favorite
        made.lastOpenedAt = opened
        return made
    }

    @Test
    func `the fixed sources come first, Recently Deleted last`() {
        let rows = LibrarySourceList.rows(
            scoreItems: [], deletedScoreItems: [], playlists: [], tags: [],
        )
        #expect(rows.map(\.source) == [.recents, .allScores, .favorites, .recentlyDeleted])
    }

    @Test
    func `counts read the live rows`() {
        let opened = item(title: "A", favorite: true, opened: Date())
        let plain = item(title: "B")
        let rows = LibrarySourceList.rows(
            scoreItems: [opened, plain], deletedScoreItems: [item(title: "C")],
            playlists: [], tags: [],
        )
        #expect(rows.first { $0.source == .allScores }?.count == 2)
        #expect(rows.first { $0.source == .favorites }?.count == 1)
        #expect(rows.first { $0.source == .recents }?.count == 1)
        #expect(rows.first { $0.source == .recentlyDeleted }?.count == 1)
    }

    @Test
    func `a playlist row counts only live members`() {
        let live = item(title: "live")
        let gone = item(title: "gone")
        let playlist = Playlist(name: "Set", orderedScoreItemIDs: [live.id, gone.id], createdAt: Self.base)
        let rows = LibrarySourceList.rows(
            scoreItems: [live], deletedScoreItems: [gone], playlists: [playlist], tags: [],
        )
        #expect(rows.first { $0.source == .playlist(playlist.id) }?.count == 1)
        #expect(rows.first { $0.source == .playlist(playlist.id) }?.title == "Set")
    }

    @Test
    func `a tag row counts only live members`() {
        let tag = Tag(name: "Recital", colorHex: "#FF0000")
        var live = item(title: "live")
        live.tagIDs = [tag.id]
        var gone = item(title: "gone")
        gone.tagIDs = [tag.id]
        let rows = LibrarySourceList.rows(
            scoreItems: [live], deletedScoreItems: [gone], playlists: [], tags: [tag],
        )
        #expect(rows.first { $0.source == .tag(tag.id) }?.count == 1)
        #expect(rows.first { $0.source == .tag(tag.id) }?.title == "Recital")
    }

    @Test
    func `playlists and tags are ordered before Recently Deleted`() {
        let playlist = Playlist(name: "Set", orderedScoreItemIDs: [], createdAt: Self.base)
        let tag = Tag(name: "Recital", colorHex: "#FF0000")
        let rows = LibrarySourceList.rows(
            scoreItems: [], deletedScoreItems: [], playlists: [playlist], tags: [tag],
        )
        #expect(rows.map(\.source) == [
            .recents, .allScores, .favorites, .playlist(playlist.id), .tag(tag.id), .recentlyDeleted,
        ])
    }
}
