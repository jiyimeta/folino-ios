@testable import Domain
import Testing

@Suite("PlaylistContinuationMode")
struct PlaylistContinuationModeTests {
    @Test
    func `raw values are stable for @AppStorage persistence`() {
        #expect(PlaylistContinuationMode.off.rawValue == "off")
        #expect(PlaylistContinuationMode.playThrough.rawValue == "playThrough")
        #expect(PlaylistContinuationMode.loopPlaylist.rawValue == "loopPlaylist")
    }

    @Test
    func `round-trips through raw value`() {
        for mode in PlaylistContinuationMode.allCases {
            #expect(PlaylistContinuationMode(rawValue: mode.rawValue) == mode)
        }
    }
}
