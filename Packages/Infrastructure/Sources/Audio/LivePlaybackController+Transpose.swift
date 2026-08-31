// PARITY(macos): transpose forwarding — depends on the gated LivePlaybackController; ports once that type does.

#if os(iOS)
import Domain
import SheetMusicAudio

extension LivePlaybackController {
    public func setTranspose(semitones: Int) {
        engine.setTranspose(semitones: max(-7, min(7, semitones)))
    }
}
#endif
