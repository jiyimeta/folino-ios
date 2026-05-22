import Domain
import Foundation
import Observation
import SheetMusicCore

/// Owns engine load/play/pause lifecycle, cursor stream subscription with hidden-staves translation, and
/// the high-quality soundfont hot-swap watcher. Created and wired by `ReaderViewModel`; views observe
/// `isPlaying` and `playbackCursor` through `viewModel.playbackSession`.
@MainActor
@Observable
final class ReaderPlaybackSession {
    private(set) var isPlaying = false
    private(set) var playbackCursor: ScoreCursor?

    @ObservationIgnored private(set) var rawPlaybackCursor: ScoreCursor?

    @ObservationIgnored let controller: (any PlaybackController)?

    @ObservationIgnored private let museScoreGeneralProvider: (any MuseScoreGeneralProvider)?
    @ObservationIgnored private var hasLoadedIntoPlayback = false
    @ObservationIgnored private var preloadTask: Task<Void, Error>?
    @ObservationIgnored private var pendingSoundfontSwap = false
    @ObservationIgnored private var soundfontDownloadTask: Task<Void, Never>?

    /// Providers — set by the owner (`ReaderViewModel`) right after init.
    var scoreProvider: () -> Score? = { nil }
    var hiddenStavesProvider: () -> Set<StaffAddress> = { [] }
    var preferencesProvider: () -> ReaderPreferences? = { nil }
    var scoreItemProvider: () -> ScoreItem? = { nil }

    /// Callbacks — fired after state transitions so the owner can fan out to PiP / repeat / etc.
    var onPlayingChanged: (Bool) -> Void = { _ in }
    var onCursorChanged: () -> Void = {}
    var onReadyForLoopForward: () async -> Void = {}

    init(
        controller: (any PlaybackController)?,
        museScoreGeneralProvider: (any MuseScoreGeneralProvider)?,
    ) {
        self.controller = controller
        self.museScoreGeneralProvider = museScoreGeneralProvider
    }

    deinit {
        soundfontDownloadTask?.cancel()
    }

    /// Kick off the engine load in the background. Idempotent — re-entry while loading or already loaded
    /// is a no-op. Cancellation is forwarded into the unstructured task so a Reader dismiss mid-prep
    /// doesn't keep the engine churning.
    func prepareForPlayback() async {
        guard let controller,
              let score = scoreProvider(),
              let prefs = preferencesProvider(),
              let scoreItem = scoreItemProvider(),
              !hasLoadedIntoPlayback,
              preloadTask == nil
        else { return }
        let initial = PlaybackPreferences.initial(
            for: score,
            readerPreferences: prefs,
            scoreItemID: scoreItem.id,
            defaultVolume: ReaderViewModel.defaultStaffVolume,
        )
        let task = Task<Void, Error> { [scoreItem] in
            try await controller.load(
                score: score, displayTitle: scoreItem.title, preferences: initial,
            )
        }
        preloadTask = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            hasLoadedIntoPlayback = true
            // PlaybackPreferences carries `abRepeat` but the engine's load path doesn't consume it.
            // Push the active loop range now that the score is loaded.
            await onReadyForLoopForward()
        } catch {
            // Cancellation or controller error — leave the slot clear so a subsequent toggle starts a
            // fresh attempt.
        }
        preloadTask = nil
    }

    /// Tear down the audio engine and reset prepare-state so the system's auto-lock can take effect once
    /// the Reader is off-screen.
    func releaseEngine() async {
        preloadTask?.cancel()
        preloadTask = nil
        await controller?.releaseEngine()
        hasLoadedIntoPlayback = false
    }

    func togglePlayback() async {
        guard let controller,
              let score = scoreProvider(),
              let prefs = preferencesProvider(),
              let scoreItem = scoreItemProvider()
        else { return }
        if !hasLoadedIntoPlayback {
            let initial = PlaybackPreferences.initial(
                for: score,
                readerPreferences: prefs,
                scoreItemID: scoreItem.id,
                defaultVolume: ReaderViewModel.defaultStaffVolume,
            )
            let task = preloadTask ?? Task<Void, Error> { [scoreItem] in
                try await controller.load(
                    score: score, displayTitle: scoreItem.title, preferences: initial,
                )
            }
            preloadTask = task
            do {
                try await task.value
                hasLoadedIntoPlayback = true
            } catch {
                preloadTask = nil
                return
            }
            // Push the persisted repeat state now that the engine has the score — covers the case where
            // the user taps play before prepareForPlayback finished.
            await onReadyForLoopForward()
            preloadTask = nil
        }
        if isPlaying {
            await controller.pause()
            setPlaying(false)
        } else {
            do {
                try await controller.play()
                setPlaying(true)
            } catch {
                setPlaying(false)
            }
        }
    }

    /// Subscribe to the controller's cursor stream. Must be called from a view-lifecycle hook
    /// (`.task` / `.onAppear`) — NOT from `init` — so only the session that SwiftUI actually retains
    /// via `@State` registers its handler.
    func startObservingCursor() {
        guard let controller else { return }
        controller.observeCursor { [weak self] value in
            guard let self else { return }
            rawPlaybackCursor = value
            applyCursorTranslation(value)
            // The engine emits a nil cursor only when playback hits the end of the score
            // (PlaybackEngine.stop() clears it; explicit pause() does not). Use that signal to flip
            // the toolbar's play/pause glyph back to "play".
            if value == nil, isPlaying {
                setPlaying(false)
            }
        }
        controller.observeIsPlaying { [weak self] playing in
            guard let self else { return }
            setPlaying(playing)
            if !playing, pendingSoundfontSwap {
                pendingSoundfontSwap = false
                Task { await self.controller?.reloadSoundfont() }
            }
        }
    }

    /// Watch the high-quality soundfont download. If it finishes while the Reader is open, hot-swap the
    /// engine's SF2 without forcing the user to reopen the score — swap immediately when paused, or
    /// queue until the next pause when actively playing. One-shot per Reader session.
    func startObservingSoundfontDownload() {
        guard let provider = museScoreGeneralProvider,
              soundfontDownloadTask == nil
        else { return }
        // Already downloaded at Reader open → the natural controller.load(...) will pick up the
        // high-quality SF2 on its own, no swap needed.
        if case .downloaded = provider.downloadState { return }
        soundfontDownloadTask = Task { @MainActor [weak self] in
            let stream = Observations { provider.downloadState }
            for await state in stream {
                guard let self else { return }
                if case .downloaded = state {
                    handleSoundfontReady()
                    return
                }
            }
        }
    }

    func setManualCursor(_ cursor: ScoreCursor) {
        let hidden = hiddenStavesProvider()
        let engineCursor = scoreProvider()?.engineCursorForFilteredTap(
            cursor,
            hiddenStaves: hidden,
        ) ?? cursor
        rawPlaybackCursor = engineCursor
        playbackCursor = cursor
        onCursorChanged()
        guard let controller else { return }
        Task { await controller.setCursor(to: engineCursor) }
    }

    /// Re-translate `rawPlaybackCursor` against the current hidden-staves set. Called by the owner
    /// after `LayoutSettingsModel.onHiddenStavesChanged`.
    func refreshTranslation() {
        applyCursorTranslation(rawPlaybackCursor)
    }

    // MARK: - Private

    private func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        onPlayingChanged(playing)
    }

    private func applyCursorTranslation(_ raw: ScoreCursor?) {
        let translated = scoreProvider()?.translateCursorForHiddenStaves(
            raw,
            hiddenStaves: hiddenStavesProvider(),
        ) ?? raw
        playbackCursor = translated
        onCursorChanged()
    }

    private func handleSoundfontReady() {
        // Engine hasn't been primed yet → prepareForPlayback / togglePlayback will consume the new
        // resolver URL on its initial load, so nothing to do here.
        guard hasLoadedIntoPlayback else { return }
        if isPlaying {
            pendingSoundfontSwap = true
        } else {
            Task { await controller?.reloadSoundfont() }
        }
    }
}
