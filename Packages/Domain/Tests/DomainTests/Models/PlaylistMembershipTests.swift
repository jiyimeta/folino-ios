@testable import Domain
import Foundation
import Testing

struct PlaylistMembershipTests {
    @Test func `appendUnique adds only absent ids, preserving order`() {
        let a = ScoreItemID()
        let b = ScoreItemID()
        let c = ScoreItemID()
        var playlist = Playlist(name: "P", orderedScoreItemIDs: [a, b], createdAt: Date())
        playlist.appendUnique([b, c, c])
        #expect(playlist.orderedScoreItemIDs == [a, b, c])
    }

    @Test func `toggleMembership appends when absent and removes when present`() {
        let a = ScoreItemID()
        let b = ScoreItemID()
        var playlist = Playlist(name: "P", orderedScoreItemIDs: [a], createdAt: Date())
        playlist.toggleMembership(b)
        #expect(playlist.orderedScoreItemIDs == [a, b])
        playlist.toggleMembership(a)
        #expect(playlist.orderedScoreItemIDs == [b])
    }

    @Test func `remove drops the given ids and keeps order`() {
        let a = ScoreItemID()
        let b = ScoreItemID()
        let c = ScoreItemID()
        var playlist = Playlist(name: "P", orderedScoreItemIDs: [a, b, c], createdAt: Date())
        playlist.remove([b])
        #expect(playlist.orderedScoreItemIDs == [a, c])
    }
}
