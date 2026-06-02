@testable import Domain
import Foundation
import Testing

struct PlaylistPresentationTests {
    @Test func `ordered live I ds keeps order and drops non live I ds`() {
        let a = ScoreItemID()
        let b = ScoreItemID()
        let c = ScoreItemID()
        let playlist = Playlist(name: "P", orderedScoreItemIDs: [a, b, c], createdAt: Date())
        let result = PlaylistPresentation.orderedLiveIDs(playlist, liveIDs: [c, a])
        #expect(result == [a, c]) // b excluded, order preserved
    }

    @Test func `live member count counts only live members`() {
        let a = ScoreItemID()
        let b = ScoreItemID()
        let c = ScoreItemID()
        let playlist = Playlist(name: "P", orderedScoreItemIDs: [a, b, c], createdAt: Date())
        #expect(PlaylistPresentation.liveMemberCount(playlist, liveIDs: [a, c]) == 2)
        #expect(PlaylistPresentation.liveMemberCount(playlist, liveIDs: []) == 0)
    }
}
