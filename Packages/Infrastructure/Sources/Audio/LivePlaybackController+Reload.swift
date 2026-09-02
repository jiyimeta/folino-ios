import Domain
import Foundation
import SheetMusicAudio
import SheetMusicCore

extension LivePlaybackController {
    /// Re-prepare the currently loaded score so the engine re-consults its `SoundfontResolver`. Used by the Reader when
    /// the high-quality MuseScore_General download finishes mid-session — the controller stays paused throughout the
    /// swap, so the caller is responsible for invoking this only when `isPlaying == false`.
    ///
    /// A second `engine.prepare(score:)` *without* teardown leaves the metronome sampler bound to the old SoundFont
    /// and silently resets `MetronomeController.isEnabled` to its default of `true` — exactly the symptoms an in-flight
    /// swap exhibited before this code path existed. Teardown forces SheetMusicAudio to rebuild every sampler the next
    /// prepare lays down, which is what closing-and-reopening the Reader was doing manually.
    public func reloadSoundfont() {
        guard let score = loadedScore, let preferences = loadedPreferences else { return }
        logger.notice("reloadSoundfont: starting full engine rebuild to pick up new SoundFont URL")
        let savedCursor = engine.currentCursor
        engine.teardown()
        do {
            try engine.prepare(score: score)
        } catch {
            logger.error("reloadSoundfont: prepare failed: \(String(describing: error), privacy: .public)")
            // The teardown above already tore down the engine, so an empty list is the truthful answer rather
            // than a stale snapshot from before the failed re-prepare.
            snapshotStrips = []
            return
        }
        engine.pause()
        snapshotStrips = stripsFromEngine()
        applyPreferences(preferences)
        // `prepare` resets the metronome channel's mute back to false — re-apply the user's preference.
        engine.setMuted(forChannel: .metronome, to: !metronomeEnabled)
        if let savedCursor {
            // Match the paused-branch behavior in `setCursor(to:)`: `seek` is a no-op until the sequencer is rebuilt by
            // the next `play()`, so stash the request so `play()` consumes it.
            engine.seek(to: savedCursor)
            pendingCursor = savedCursor
        }
        publishNowPlayingInfo()
        let metronomeOn = metronomeEnabled
        logger.notice("reloadSoundfont: complete (metronomeEnabled=\(metronomeOn, privacy: .public))")
    }
}
