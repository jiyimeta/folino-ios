import Domain
import SheetMusicAudio

extension LivePlaybackController {
    public func setTranspose(semitones: Int) {
        engine.setTranspose(semitones: max(-7, min(7, semitones)))
    }
}
