import Domain
import UtilityCore

// MARK: - Playback-session / PiP wiring

/// Wires the playback session's and PiP session's provider/callback closures back to the view model. Split out of
/// `ReaderViewModel.swift` to keep that file within the file-length budget; called once from the VM's `init`.
extension ReaderViewModel {
    func wirePlaybackSession() {
        // `playbackScore` is the natively loaded score, or — for a PDF — its parsed-for-playback score
        // once OMR succeeds, so the whole transport / cursor / seek path works for PDFs unchanged.
        playbackSession.scoreProvider = { [weak self] in self?.playbackScore }
        playbackSession.seekTimelineProvider = { [weak self] in self?.seekTimeline ?? .empty }
        playbackSession.hiddenStavesProvider = { [weak self] in self?.layoutModel.hiddenStaves ?? [] }
        playbackSession.preferencesProvider = { [weak self] in self?.preferences }
        playbackSession.scoreItemProvider = { [weak self] in self?.scoreItem }
        playbackSession.onPlayingChanged = { [weak self] playing in
            guard let self else { return }
            pipSession.onPlayingChanged(to: playing)
            // Fires once per play-start transition (the session guards duplicate `setPlaying` calls). Covers user taps,
            // PiP, and playlist auto-advance — every path that genuinely begins playback.
            if playing {
                analytics.log(.playbackStarted(layoutMode: currentLayoutMode, from: openedFrom))
            }
        }
        playbackSession.onCursorChanged = { [weak self] in
            self?.pipSession.notifyCursorChanged()
        }
        playbackSession.onReadyForLoopForward = { [weak self] in
            await self?.repeatModel.forwardLoopRangeToController()
        }
        // The mixer draws what the engine holds, so its strip list is re-read at every path that leaves a score
        // prepared — both loads and the soundfont hot-swap — rather than being derived from the score here.
        playbackSession.onEnginePrepared = { [weak self] in
            await self?.mixerModel.refreshStrips()
        }
        playbackSession.onReachedEnd = { [weak self] in
            await self?.handlePlaybackReachedEnd()
        }
    }

    func wirePiPSession() {
        pipSession.scoreProvider = { [weak self] in self?.loadState.score }
        pipSession.isPlayingProvider = { [weak self] in self?.playbackSession.isPlaying ?? false }
        pipSession.playbackCursorProvider = { [weak self] in self?.playbackSession.playbackCursor }
        pipSession.scrollAnchorCursorProvider = { [weak self] in self?.playbackSession.scrollAnchorCursor }
        pipSession.layoutSnapshotProvider = { [weak self] in self?.currentPiPLayoutSnapshot() }
        pipSession.playbackController = playbackSession.controller
        pipSession.onTogglePlayback = { [weak self] in await self?.togglePlayback() }
    }

    private func currentPiPLayoutSnapshot() -> PiPLayoutSnapshot {
        PiPLayoutSnapshot(
            staffSize: layoutModel.effectiveStaffSize,
            hiddenStaves: layoutModel.hiddenStaves,
            clefOverrides: layoutModel.staffClefOverrides,
            transposeSemitones: transposeModel.effectiveSemitones,
        )
    }
}
