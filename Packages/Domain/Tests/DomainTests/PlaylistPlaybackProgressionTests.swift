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

    @Test
    func `wire form: stop maps to -1, advance maps to the index`() {
        // playThrough: middle advances, last stops
        #expect(P.nextActionWire(
            currentIndex: 0, count: 3, repeatModeRawValue: "off", continuationRawValue: "playThrough",
        ) == 1)
        #expect(P.nextActionWire(
            currentIndex: 2, count: 3, repeatModeRawValue: "off", continuationRawValue: "playThrough",
        ) == -1)
        // loopPlaylist: last wraps to 0
        #expect(P.nextActionWire(
            currentIndex: 2, count: 3, repeatModeRawValue: "off", continuationRawValue: "loopPlaylist",
        ) == 0)
        // repeat active always stops
        #expect(P.nextActionWire(
            currentIndex: 0, count: 3, repeatModeRawValue: "loopAll", continuationRawValue: "loopPlaylist",
        ) == -1)
        // unknown raw values fall back to .off → stop
        #expect(P.nextActionWire(
            currentIndex: 0, count: 3, repeatModeRawValue: "??", continuationRawValue: "??",
        ) == -1)
    }
}
