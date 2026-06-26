import Domain
import UtilityCore

// MARK: - Transport / inspector action facade

/// Thin action methods the transport and overlay views call instead of poking `playbackSession` directly, so each
/// user-initiated transport action is logged once at its real action site (after the state change) against the same
/// `analytics` sink as the VM-owned playback-lifecycle events.
extension ReaderViewModel {
    /// Toggle play / pause. `playback_started` is logged centrally from the session's playing-changed callback (it also
    /// covers playlist auto-advance and PiP); here we only stamp the explicit user pause.
    func togglePlayback() async {
        let wasPlaying = playbackSession.isPlaying
        await playbackSession.togglePlayback()
        if wasPlaying, !playbackSession.isPlaying {
            analytics.log(.playbackControl(action: "pause"))
        }
    }

    func stepMeasureForward() {
        playbackSession.stepMeasureForward()
        analytics.log(.playbackControl(action: "next"))
    }

    func stepMeasureBackward() {
        playbackSession.stepMeasureBackward()
        analytics.log(.playbackControl(action: "previous"))
    }

    func seekToStart() {
        playbackSession.seekToStart()
        analytics.log(.playbackControl(action: "seek"))
    }

    /// Records the control event for a committed seek-bar scrub. `SeekRegion` owns the `playbackSession.endScrub()`
    /// call; this stays a pure log so the seek view keeps depending only on the session, not the analytics types.
    func logSeekCommitted() {
        analytics.log(.playbackControl(action: "seek"))
    }

    /// Present the score-info sheet from the reader overlay, logging the open.
    func presentScoreInfo() {
        isScoreInfoPresented = true
        analytics.log(.scoreInfoOpened(source: .readerOverlay))
    }

    /// Log a `tempo_changed` with the slider's net direction, comparing the freshly committed multiplier against the
    /// last logged baseline. A commit that nets to no change (e.g. release at the same value) logs nothing. Called from
    /// the tempo model's `onChange` wiring.
    func logTempoChangeIfNeeded() {
        let new = tempoModel.effectiveMultiplier
        guard new != lastTempoMultiplier else { return }
        analytics.log(.tempoChanged(direction: new > lastTempoMultiplier ? "increase" : "decrease"))
        lastTempoMultiplier = new
    }

    /// Log a `transpose_changed` with the up/down direction. `TransposeModel.setSemitones` only fires `onChange` on a
    /// real change, so this always reflects a genuine semitone move relative to the last logged baseline.
    func logTransposeChangeIfNeeded() {
        let new = transposeModel.semitones
        guard new != lastTransposeSemitones else { return }
        analytics.log(.transposeChanged(direction: new > lastTransposeSemitones ? "up" : "down"))
        lastTransposeSemitones = new
    }
}
