@testable import Domain
import Foundation
import Testing

struct PlaylistTests {
    @Test func `preserves score order`() {
        let s1 = ScoreItemID()
        let s2 = ScoreItemID()
        let s3 = ScoreItemID()
        let p = Playlist(
            id: PlaylistID(),
            name: "Recital 1",
            orderedScoreItemIDs: [s1, s2, s3],
            createdAt: Date(),
        )
        #expect(p.orderedScoreItemIDs == [s1, s2, s3])
    }

    @Test func `is order sensitive in equality`() {
        let s1 = ScoreItemID()
        let s2 = ScoreItemID()
        let id = PlaylistID()
        let date = Date(timeIntervalSince1970: 0)
        let a = Playlist(id: id, name: "x", orderedScoreItemIDs: [s1, s2], createdAt: date)
        let b = Playlist(id: id, name: "x", orderedScoreItemIDs: [s2, s1], createdAt: date)
        #expect(a != b)
    }

    @Test func `round trips through codable`() throws {
        let p = Playlist(
            id: PlaylistID(),
            name: "Recital 1",
            orderedScoreItemIDs: [ScoreItemID(), ScoreItemID()],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Playlist.self, from: data)
        #expect(decoded == p)
    }
}
