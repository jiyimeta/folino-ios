// swiftlint:disable file_length
// ReaderPlaybackSession owns the whole engine lifecycle — load / play / pause, the cursor stream with hidden-staves
// translation, scrub + manual-cursor seeking, playback-follow suspension, and the soundfont hot-swap watcher; that
// cohesive surface keeps it just over the file_length budget.

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

    /// Runtime, session-scoped suspension of playback cursor auto-follow (auto-scroll / auto-page-turn). Set when the
    /// user takes manual control of the viewport — scroll, pinch-zoom, or page-turn — WHILE playing; cleared when
    /// playback (re)starts or the cursor is set manually (tap-seek / measure-step / scrub commit). Independent of the
    /// persistent `readerAutoFollowEnabled` opt-out: it lets a reader temporarily look ahead / back during playback
    /// without the page yanking to the playhead every cursor tick. Read at the containers' follow gate via
    /// `readerShouldFollowPlayback(..., followSuspended:)`.
    private(set) var isPlaybackFollowSuspended = false

    /// Provisional cursor shown while the user drags the seek bar. Non-nil only mid-scrub. The score
    /// views render `displayCursor`, so they follow this instead of the live `playbackCursor`; audio
    /// and the real cursor stay put until `endScrub()`.
    private(set) var scrubCursor: ScoreCursor?

    /// What the on-screen score should highlight and auto-scroll to: the provisional scrub position
    /// when dragging, otherwise the live playback cursor.
    var displayCursor: ScoreCursor? {
        scrubCursor ?? playbackCursor
    }

    /// Lookahead anchor for vertical-mode auto-scroll: the `.beat` cursor `scrollLookaheadBeats` beats after
    /// the live position, so the score scrolls before the playing cursor reaches the viewport edge. Non-nil
    /// ONLY during continuous playback (not paused / stopped / scrubbing); callers fall back to `displayCursor`
    /// when nil, preserving the reactive scroll behavior. Never drives the on-staff highlight.
    ///
    /// Computed from `rawPlaybackCursor` (the engine's full-score address) so an `.item` cursor resolves its
    /// tick against the right staff — exactly as `playbackFraction` does. The `.beat` result is staff-agnostic,
    /// so no hidden-staves translation is needed.
    var scrollAnchorCursor: ScoreCursor? {
        guard isPlaying, scrubCursor == nil,
              let raw = rawPlaybackCursor, let score = scoreProvider()
        else { return nil }
        return score.cursor(advancedByBeats: Self.scrollLookaheadBeats, from: raw)
    }

    /// Lead distance for `scrollAnchorCursor`, in quarter-note beats. Code-tunable single source of truth.
    static let scrollLookaheadBeats: Double = 2

    /// Lookahead anchor for PAGE mode: the `.beat` cursor `pageLookaheadBeats` beats ahead of the live
    /// position, so the page turns before the playhead reaches the next page. Non-nil ONLY during continuous
    /// playback (not paused / stopped / scrubbing); page mode falls back to `displayCursor` when nil. Never
    /// drives the highlight. Computed from `rawPlaybackCursor` (full-score address); the `.beat` result is
    /// staff-agnostic.
    var pageAnchorCursor: ScoreCursor? {
        guard isPlaying, scrubCursor == nil,
              let raw = rawPlaybackCursor, let score = scoreProvider()
        else { return nil }
        return score.cursor(advancedByBeats: Self.pageLookaheadBeats, from: raw)
    }

    /// Lead for `pageAnchorCursor`, in quarter-note beats. Shorter than `scrollLookaheadBeats` so the playhead
    /// is only briefly on the prior page during an anticipatory page turn.
    static let pageLookaheadBeats: Double = 1

    /// Live playback position as a 0...1 fraction of the notated timeline, computed in FULL-SCORE coordinates.
    ///
    /// The seek bar must read this rather than mapping `playbackCursor` itself: `playbackCursor` carries *filtered*
    /// staff addresses for the on-screen (hidden-staves) layout lookup, and `Score.seconds(at:)` resolves an `.item`
    /// cursor's tick by walking that staff's voice. Fed the unfiltered score, a re-stamped `.item` cursor would walk a
    /// *different* full-score staff — at best a wrong tick, at worst a crash on a whole-measure rest.
    /// `rawPlaybackCursor` keeps the engine's original full-score address, so it resolves against the right staff.
    /// Scrubbing is handled by the seek bar's own provisional fraction and intentionally not reflected here.
    /// Placed from the cached `ReaderSeekTimeline` rather than `Score.seconds(at:)`, which re-derives every prior
    /// measure's governing tempo on every call — quadratic in measure count, and this runs on **every cursor tick**.
    /// That cost is what made the transport stutter while a swipe was in progress during playback. Only the tick
    /// within the cursor's own measure still needs the score, and resolving that walks one measure, not all of them.
    var playbackFraction: Double {
        guard let cursor = rawPlaybackCursor, let score = scoreProvider() else { return 0 }
        return seekTimelineProvider().fraction(
            measureIndex: cursor.measureIndex,
            tickInMeasure: score.tickInMeasure(of: cursor),
        )
    }

    /// Latest 0...1 fraction from `updateScrub`, used by `endScrub` to seek the audio by time on release.
    @ObservationIgnored private var lastScrubFraction: Double = 0

    /// Engine's original full-score-addressed cursor (pre hidden-staves translation). Observed — `playbackFraction`
    /// reads it, so the seek bar re-renders as it advances. Set in lockstep with `playbackCursor` on every cursor
    /// update / seek.
    private var rawPlaybackCursor: ScoreCursor?

    @ObservationIgnored let controller: (any PlaybackController)?

    /// Reads the user's global count-in preference at the moment `togglePlayback()` presses play.
    /// `ReaderGlobalSettingsKey.precountEnabled` — overridable in tests.
    @ObservationIgnored var isPrecountEnabled: () -> Bool = {
        UserDefaults.standard.bool(forKey: ReaderGlobalSettingsKey.precountEnabled)
    }

    @ObservationIgnored private let museScoreGeneralProvider: (any MuseScoreGeneralProvider)?
    @ObservationIgnored private var hasLoadedIntoPlayback = false
    @ObservationIgnored private var preloadTask: Task<Void, Error>?
    @ObservationIgnored private var pendingSoundfontSwap = false
    @ObservationIgnored private var soundfontDownloadTask: Task<Void, Never>?

    /// Providers — set by the owner (`ReaderViewModel`) right after init.
    var scoreProvider: () -> Score? = { nil }
    /// The owner's cached per-measure timing table, so placing the playhead never walks the score. Deliberately the
    /// same table the seek bar draws its marks and time readout from, so the thumb can't disagree with them.
    var seekTimelineProvider: () -> ReaderSeekTimeline = { .empty }
    var hiddenStavesProvider: () -> Set<StaffAddress> = { [] }
    /// Where a press of play should seek to first, or nil to carry on from wherever the cursor already is. Wired by
    /// `ReaderRootScreen` to the editing selection; nothing outside edit mode supplies one.
    var startCursorProvider: () -> ScoreCursor? = { nil }
    var preferencesProvider: () -> ReaderPreferences? = { nil }
    var scoreItemProvider: () -> ScoreItem? = { nil }

    /// Callbacks — fired after state transitions so the owner can fan out to PiP / repeat / etc.
    var onPlayingChanged: (Bool) -> Void = { _ in }
    var onCursorChanged: () -> Void = {}
    var onReadyForLoopForward: () async -> Void = {}
    /// Fired whenever the engine ends up holding a freshly prepared score: after each of the two load paths, and after
    /// a soundfont hot-swap re-prepares it. The owner refreshes the mixer's strip list here — the strips are a product
    /// of that preparation, so anchoring to only one of the load paths would leave the mixer empty for the whole
    /// session whenever the other one ran.
    var onEnginePrepared: () async -> Void = {}

    /// Fired exactly when the engine reports end-of-score (`cursor == nil` while playing). The owner decides whether to
    /// advance to the next playlist score. Not fired on manual pause/stop — only natural end.
    var onReachedEnd: () async -> Void = {}

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
            readerPreferences: prefs,
            scoreItemID: scoreItem.id,
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
            await onEnginePrepared()
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
                readerPreferences: prefs,
                scoreItemID: scoreItem.id,
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
            await onEnginePrepared()
            preloadTask = nil
        }
        if isPlaying {
            await controller.pause()
            setPlaying(false)
        } else {
            // Start from whatever the editor has selected, if anything: while editing, the selected note is where the
            // user's attention is, and hearing the passage from there is the point of playing at all mid-edit.
            if let start = startCursorProvider() {
                placeCursor(start)
            }
            do {
                try await controller.play(countIn: isPrecountEnabled())
                // Resuming playback re-arms auto-follow: any suspension from the previous play run (the user having
                // scrolled / pinched / turned the page by hand) is cleared so the page follows the playhead again.
                resumePlaybackFollow()
                setPlaying(true)
            } catch {
                setPlaying(false)
            }
        }
    }

    /// Subscribe to the controller's cursor stream. Must be called from a view-lifecycle hook
    /// (`.task` / `.onAppear`) — NOT from the view model's `init` — so only the view model that SwiftUI
    /// actually retains via `@State` registers its session's handler. Calling from `init` regressed the
    /// playback cursor: SwiftUI re-evaluates the `@State(wrappedValue:)` expression on every parent body
    /// pass, constructing a fresh VM (and thus a fresh session) each time, but keeps only the first as
    /// the persisted state. The subsequent throwaway sessions all register handlers that capture
    /// themselves weakly, the last one wins, and once it's deallocated the engine's cursor changes land
    /// on a `[weak self]` that's already nil.
    func startObservingCursor() {
        guard let controller else { return }
        controller.observeCursor { [weak self] value in
            guard let self else { return }
            rawPlaybackCursor = value
            applyCursorTranslation(value)
            // A nil cursor means the engine called `stop()` — either playback reached the end of the score
            // or we tore the engine down via `releaseEngine()` (explicit `pause()` does NOT nil the cursor).
            // Guard on `hasLoadedIntoPlayback`, NOT `isPlaying`: `PlaybackEngine.stop()` sets `state = .stopped`
            // *before* `currentCursor = nil`, so the `observeIsPlaying` stream has already flipped `isPlaying`
            // to false by the time this nil arrives — an `isPlaying` guard would never pass at natural end
            // (the playlist auto-advance would never fire). `hasLoadedIntoPlayback` is still true at natural end
            // and is cleared synchronously inside `releaseEngine()` before its teardown nil is delivered, so it
            // distinguishes "reached the end while loaded" from "we tore the engine down".
            if value == nil, hasLoadedIntoPlayback {
                setPlaying(false)
                Task { [weak self] in await self?.onReachedEnd() }
            }
        }
        controller.observeIsPlaying { [weak self] playing in
            guard let self else { return }
            setPlaying(playing)
            if !playing, pendingSoundfontSwap {
                pendingSoundfontSwap = false
                Task { [weak self] in await self?.swapSoundfont() }
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
        if #available(iOS 26, *) {
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
        } else {
            // iOS 18 fallback for the `Observations` stream above: `Observations` itself is iOS 26+, and this
            // one-shot "wait for the download to finish" doesn't need push-based delivery, so a coarse poll is a
            // simple, low-risk substitute — the download itself takes seconds, so a half-second interval is
            // imperceptible. Polling (rather than a recursive `withObservationTracking` re-arm, as used in
            // `LivePlaybackController`'s iOS 18 fallback) also means `Task.sleep`'s cancellation support makes
            // `deinit`'s `soundfontDownloadTask?.cancel()` actually stop the loop promptly.
            soundfontDownloadTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if case .downloaded = provider.downloadState {
                        handleSoundfontReady()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    /// Reset the playback position to the very start of the score (first measure, first tick) without touching the
    /// play / pause state — a transport "rewind to top". The score containers observe `playbackCursor` and scroll /
    /// page back to the opening measure.
    func seekToStart() {
        seek(toMeasureStart: 0)
    }

    /// Advance the cursor to the start of the next measure (clamped to the last measure), preserving play / pause
    /// state.
    func stepMeasureForward() {
        guard let score = scoreProvider() else { return }
        let from = rawPlaybackCursor ?? .beat(measureIndex: 0, tickInMeasure: 0)
        let target = score.cursorSteppingMeasure(from: from, direction: .forward)
        seek(toMeasureStart: target.measureIndex)
    }

    /// Step the cursor back by a measure, preserving play / pause state. If the cursor is still within the first beat
    /// of its measure (before the 2nd beat begins), jump to the previous measure; otherwise restart the current
    /// measure — the familiar media-player "previous" behaviour.
    func stepMeasureBackward() {
        guard let score = scoreProvider() else { return }
        let from = rawPlaybackCursor ?? .beat(measureIndex: 0, tickInMeasure: 0)
        let target = score.cursorSteppingMeasure(from: from, direction: .backward)
        seek(toMeasureStart: target.measureIndex)
    }

    /// Seek the cursor to the first tick of `measureIndex` without changing play / pause state. A `.beat` cursor is
    /// staff-agnostic, so no hidden-staves translation is needed.
    private func seek(toMeasureStart measureIndex: Int) {
        // A manual measure-step / seek-to-start is an explicit cursor set → resume follow so the container re-centers
        // this target and continued playback keeps following.
        resumePlaybackFollow()
        let target = ScoreCursor.beat(measureIndex: measureIndex, tickInMeasure: 0)
        rawPlaybackCursor = target
        playbackCursor = target
        onCursorChanged()
        guard let controller else { return }
        Task { await controller.setCursor(to: target) }
    }

    /// Takes the playhead off the score without moving the engine. Used when the editor selects a note: the selection
    /// becomes the "you are here" mark, and a second one left over from the last listen only competes with it. The
    /// engine's own position (`rawPlaybackCursor`, which the seek bar reads and play resumes from) is untouched, so
    /// this is a display change only — and never while playing, where the playhead is the whole point.
    func hideDisplayedCursor() {
        guard !isPlaying, scrubCursor == nil else { return }
        playbackCursor = nil
    }

    func setManualCursor(_ cursor: ScoreCursor) {
        let engineCursor = placeCursor(cursor)
        // Audition the tapped note while stopped / paused only — never overlay a one-shot preview on a continuous
        // playback stream. Use the engine (full-score addressed) cursor so the NoteID resolves against the score the
        // engine prepared; rests fall through silently.
        if !isPlaying, case let .item(.note(noteID)) = engineCursor {
            Task { await controller?.playPreview(noteID: noteID, duration: 0.5) }
        }
    }

    /// The cursor move itself, without the tap's audition. Split out because pressing play with an editing selection
    /// also seeks — and there, a 0.5 s preview of the first note would sound over the top of playback starting on
    /// that very note. Returns the engine-addressed cursor the caller may want to inspect.
    @discardableResult
    private func placeCursor(_ cursor: ScoreCursor) -> ScoreCursor {
        // Placing the cursor by hand is an explicit manual set → resume follow (clears any suspension from the user
        // having scrolled away during playback).
        resumePlaybackFollow()
        let hidden = hiddenStavesProvider()
        let engineCursor = scoreProvider()?.engineCursorForFilteredTap(
            cursor,
            hiddenStaves: hidden,
        ) ?? cursor
        rawPlaybackCursor = engineCursor
        playbackCursor = cursor
        onCursorChanged()
        if let controller {
            Task { await controller.setCursor(to: engineCursor) }
        }
        return engineCursor
    }

    /// Begin an interactive seek-bar drag. Seeds the provisional cursor at the current real position so
    /// the score doesn't jump before the first drag delta arrives.
    func beginScrub() {
        scrubCursor = playbackCursor ?? .beat(measureIndex: 0, tickInMeasure: 0)
    }

    /// Move the provisional cursor to `fraction` (0...1) of the notated timeline. Views following
    /// `displayCursor` re-scroll / page; audio and the real cursor are untouched.
    func updateScrub(toFraction fraction: Double) {
        guard let score = scoreProvider() else { return }
        let clamped = min(max(fraction, 0), 1)
        lastScrubFraction = clamped
        scrubCursor = score.cursor(atSeconds: clamped * score.notatedDurationSeconds)
        onCursorChanged()
    }

    /// Commit the drag. Seek the audio by TIME rather than by cursor: the engine resolves an arbitrary time to a
    /// frame (`timeline.frame(atTime:)`), whereas `setCursor` resolves a cursor to a frame
    /// (`timeline.frame(forCursor:)`) and silently no-ops on a `.beat` whose interpolated tick doesn't land on a
    /// notated event — which is exactly what scrubbing produces. Move the real cursor to the provisional position for
    /// immediate feedback (the engine's cursor stream then re-syncs it), and clear scrub state.
    func endScrub() {
        guard let target = scrubCursor else { return }
        // Committing a seek-bar scrub is a manual cursor set → resume follow.
        resumePlaybackFollow()
        let fraction = lastScrubFraction
        rawPlaybackCursor = target
        playbackCursor = target
        scrubCursor = nil
        onCursorChanged()
        guard let controller else { return }
        Task {
            // `fraction` is multiplier-invariant and `totalTimeSeconds` scales with the tempo multiplier, so the
            // product lands at the right proportion of the engine's timeline regardless of the current rate.
            let targetTime = fraction * controller.totalTimeSeconds
            await controller.skip(bySeconds: targetTime - controller.currentTimeSeconds)
        }
    }

    /// Re-translate `rawPlaybackCursor` against the current hidden-staves set. Called by the owner
    /// after `LayoutSettingsModel.onHiddenStavesChanged`.
    func refreshTranslation() {
        applyCursorTranslation(rawPlaybackCursor)
    }

    /// The user scrolled, pinch-zoomed, or turned the page by hand. While playback is active this suspends cursor
    /// auto-follow (auto-scroll / auto-page-turn) until playback restarts or the cursor is set manually — so the reader
    /// can look ahead / back without the page snapping back to the playhead. A no-op when not playing: there is nothing
    /// to follow while paused / stopped, and a stray gesture must not leave a suspension that survives into the next
    /// play (the next play resumes following regardless, via `resumePlaybackFollow`).
    func suspendPlaybackFollowForManualViewportChange() {
        guard isPlaying else { return }
        isPlaybackFollowSuspended = true
    }

    // MARK: - Private

    /// Clear the manual-viewport suspension so playback auto-follow resumes. Called when playback (re)starts or the
    /// user sets the cursor by hand (tap-seek / measure-step / seek-to-start / scrub commit).
    private func resumePlaybackFollow() {
        isPlaybackFollowSuspended = false
    }

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
            Task { [weak self] in await self?.swapSoundfont() }
        }
    }

    /// Hot-swap the engine's SF2. The swap re-prepares the loaded score, so the strips the mixer draws are rebuilt
    /// with it — hence the `onEnginePrepared` fan-out at the end rather than at the two load paths alone.
    private func swapSoundfont() async {
        await controller?.reloadSoundfont()
        await onEnginePrepared()
    }
}
