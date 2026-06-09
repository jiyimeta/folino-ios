@testable import Domain
import Testing

@Suite("PlaylistPlaybackProgression.nextAction")
struct PlaylistPlaybackProgressionTests {
    typealias P = PlaylistPlaybackProgression

    private func act(
        _ index: Int,
        of count: Int,
        repeatMode: RepeatMode = .off,
        _ continuation: PlaylistContinuationMode,
    ) -> P.Advance {
        P.nextAction(currentIndex: index, count: count, repeatMode: repeatMode, continuation: continuation)
    }

    @Test
    func `repeat active always stops, regardless of continuation`() {
        for mode in PlaylistContinuationMode.allCases {
            #expect(act(0, of: 3, repeatMode: .loopAll, mode) == .stop)
            #expect(act(0, of: 3, repeatMode: .abLoop, mode) == .stop)
        }
    }

    @Test
    func `continuation off stops`() {
        #expect(act(0, of: 3, .off) == .stop)
    }

    @Test
    func `playThrough advances in the middle, stops at the last`() {
        #expect(act(0, of: 3, .playThrough) == .advance(toIndex: 1))
        #expect(act(1, of: 3, .playThrough) == .advance(toIndex: 2))
        #expect(act(2, of: 3, .playThrough) == .stop)
    }

    @Test
    func `loopPlaylist advances in the middle, wraps to 0 at the last`() {
        #expect(act(1, of: 3, .loopPlaylist) == .advance(toIndex: 2))
        #expect(act(2, of: 3, .loopPlaylist) == .advance(toIndex: 0))
    }

    @Test
    func `single-item playlist: playThrough stops, loopPlaylist repeats that item`() {
        #expect(act(0, of: 1, .playThrough) == .stop)
        #expect(act(0, of: 1, .loopPlaylist) == .advance(toIndex: 0))
    }

    @Test
    func `empty or out-of-range stops`() {
        #expect(act(0, of: 0, .playThrough) == .stop)
        #expect(act(-1, of: 3, .playThrough) == .stop)
        #expect(act(5, of: 3, .loopPlaylist) == .stop)
    }
}
