// swiftlint:disable file_length
import CoreGraphics
import Domain
import Foundation
import Observation
import SheetMusicCore

@MainActor
@Observable
// swiftlint:disable:next type_body_length
final class ReaderViewModel {
    enum LoadState {
        case loading
        case loaded(Score)
        case failed(message: String)

        var score: Score? {
            if case let .loaded(score) = self { return score }
            return nil
        }
    }

    /// Which copy the playback-prep alert should show. The view binds
    /// presentation to whether this is non-nil and renders the title
    /// from the case.
    enum SoundfontAlertKind {
        /// Soundfonts are still being prepared and the user pressed
        /// play before the work finished.
        case loading
        /// The device is offline AND the cache doesn't already cover
        /// every voice this score needs — the wait won't make progress
        /// until connectivity is back.
        case offline
    }

    static let defaultStaffVolume = 1.0

    /// Always the same instance (set once at init); declared `var` only so
    /// `@Bindable` projections like `$viewModel.repeatModel.mode` type-check —
    /// the chain needs the intermediate path to be writable.
    var repeatModel = RepeatModel()
    var tempoModel = TempoModel()
    var layoutModel = LayoutSettingsModel()
    var mixerModel = PlaybackMixerModel()

    private(set) var loadState: LoadState = .loading
    private(set) var scoreItem: ScoreItem
    private(set) var preferences: ReaderPreferences
    private(set) var isPlaying = false
    private(set) var soundfontAlertKind: SoundfontAlertKind?
    private(set) var playbackCursor: ScoreCursor?
    var viewportZoom: CGFloat = 1.0
    var lastNonUnitZoom: CGFloat = 1.0
    var isPlaybackInspectorPresented = false
    var isVisualInspectorPresented = false
    var isPiPActive = false

    var isPiPSupported: Bool {
        ScorePiPCoordinator.isSupported
    }

    @ObservationIgnored
    private var pipCoordinatorBacking: ScorePiPCoordinator?

    var pipCoordinator: ScorePiPCoordinator {
        if let c = pipCoordinatorBacking { return c }
        let c = ScorePiPCoordinator()
        c.onPiPStarted = { [weak self] in self?.isPiPActive = true }
        c.onPiPStopped = { [weak self] in self?.isPiPActive = false }
        c.isAppPlayingProvider = { [weak self] in self?.isPlaying ?? false }
        c.onSetPlaying = { [weak self] desired in
            guard let self, isPlaying != desired else { return }
            Task { await self.togglePlayback() }
        }
        c.currentTimeProvider = { [weak self] in
            self?.playbackController?.currentTimeSeconds ?? 0
        }
        c.totalTimeProvider = { [weak self] in
            self?.playbackController?.totalTimeSeconds ?? 0
        }
        c.onSkip = { [weak self] seconds in
            guard let controller = self?.playbackController else { return }
            Task { await controller.skip(bySeconds: seconds) }
        }
        pipCoordinatorBacking = c
        return c
    }

    @ObservationIgnored
    private var isPiPEnabled = false
    @ObservationIgnored
    private var collapseMultiMeasureRests = false

    /// Applies the user's Settings preference. Driven by the
    /// `readerPictureInPictureEnabled` `@AppStorage` value in
    /// `ReaderRootScreen`.
    func setPiPEnabled(_ enabled: Bool) {
        guard isPiPSupported else { return }
        isPiPEnabled = enabled
        pipCoordinator.setAutoStartFromBackground(enabled)
        if enabled {
            armPiPIfReady()
        } else {
            pipCoordinator.dismissIfActive()
            pipCoordinator.disarm()
        }
    }

    func setCollapseMultiMeasureRests(_ enabled: Bool) {
        guard collapseMultiMeasureRests != enabled else { return }
        collapseMultiMeasureRests = enabled
        // Re-arm PiP immediately so a currently-armed session re-lays
        // out with the new policy. No-op when PiP is disabled or the
        // score hasn't finished loading — `armPiPIfReady` guards both.
        armPiPIfReady()
    }

    /// Called from `ReaderRootScreen`'s `scenePhase` observer when the
    /// app returns to the foreground — the Settings spec dismisses PiP
    /// on return regardless of why it started.
    func dismissPiPOnForeground() {
        guard isPiPActive else { return }
        pipCoordinator.dismissIfActive()
    }

    private func armPiPIfReady() {
        guard isPiPEnabled, case let .loaded(score) = loadState else { return }
        // Mirror the on-screen transformation so the PiP view sees the
        // same staves and clefs as the main Reader pane.
        let visible = score
            .applying(clefOverrides: layoutModel.staffClefOverrides)
            .filtered(hidingStaves: layoutModel.hiddenStaves)
        do {
            try pipCoordinator.arm(
                score: visible,
                staffSize: layoutModel.staffSize,
                playbackCursor: playbackCursor,
                collapseMultiMeasureRests: collapseMultiMeasureRests,
            )
        } catch {
            // Coordinator throws only when no display layer is attached
            // (the host view hasn't mounted yet). Arming will retry once
            // the view installs the layer and load() finishes — neither
            // ordering is fatal.
        }
    }

    /// Convenience for tests and previews — true while the "loading
    /// playback sounds…" copy is showing.
    var isLoadingSoundfonts: Bool {
        soundfontAlertKind == .loading
    }

    /// Convenience for tests and previews — true while the offline
    /// copy is showing.
    var isOfflineAlertPresented: Bool {
        soundfontAlertKind == .offline
    }

    @ObservationIgnored
    private let repository: any ScoreLibraryRepository
    @ObservationIgnored
    private let gateway: any ScoreFileGateway
    @ObservationIgnored
    private let scoresDirectory: URL
    @ObservationIgnored
    private let defaultStaffSize: CGFloat
    @ObservationIgnored
    let playbackController: (any PlaybackController)?
    @ObservationIgnored
    let reachability: (any NetworkReachability)?
    @ObservationIgnored
    private var hasUpdatedLastOpened = false
    @ObservationIgnored
    private var hasLoadedIntoPlayback = false
    @ObservationIgnored
    private var preloadTask: Task<Void, Error>?
    /// Untranslated cursor as the engine published it. Kept so we can
    /// re-derive `playbackCursor` whenever `hiddenStaves` changes — the
    /// engine doesn't know about visibility, so the same raw value can
    /// map to a different visible representation across toggles.
    @ObservationIgnored
    private var rawPlaybackCursor: ScoreCursor?

    init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL,
        defaultStaffSize: CGFloat = 14,
        playbackController: (any PlaybackController)? = nil,
        reachability: (any NetworkReachability)? = nil,
    ) {
        self.scoreItem = scoreItem
        self.repository = repository
        self.gateway = gateway
        self.scoresDirectory = scoresDirectory
        self.defaultStaffSize = defaultStaffSize
        self.playbackController = playbackController
        self.reachability = reachability
        preferences = ReaderPreferences(
            scoreItemID: scoreItem.id,
            staffSize: defaultStaffSize,
            hiddenStaves: [],
        )
        wireRepeatModel()
        wireTempoModel()
        wireLayoutModel()
        wireMixerModel()
    }

    private func wireMixerModel() {
        mixerModel.host = self
        mixerModel.onChange = { [weak self] in
            guard let self else { return }
            await mutatePreferences { prefs in
                prefs.staffProgramOverrides = self.mixerModel.staffProgramOverrides
                prefs.staffVolumeOverrides = self.mixerModel.staffVolumeOverrides
            }
        }
    }

    private func wireLayoutModel() {
        layoutModel.onChange = { [weak self] in
            guard let self else { return }
            await mutatePreferences { prefs in
                prefs.staffSize = self.layoutModel.staffSize
                prefs.honorLayoutBreaks = self.layoutModel.honorLayoutBreaks
                prefs.hiddenStaves = self.layoutModel.hiddenStaves
                prefs.staffClefOverrides = self.layoutModel.staffClefOverrides
            }
            // Clef override edits land only through this path
            // (hidden-staves changes also fire `onHiddenStavesChanged`),
            // so rebuild the PiP renderer here to pick them up.
            armPiPIfReady()
        }
        layoutModel.onHiddenStavesChanged = { [weak self] in
            guard let self else { return }
            // Re-translate against the new visibility so the cursor recovers
            // immediately when the staff comes back, and falls back to .beat
            // immediately when one is hidden mid-playback.
            playbackCursor = loadState.score?.translateCursorForHiddenStaves(
                rawPlaybackCursor,
                hiddenStaves: layoutModel.hiddenStaves,
            ) ?? rawPlaybackCursor
            notifyPiPCursor()
            // AVKit fixes the PiP window's aspect ratio at session start
            // and won't renegotiate when we feed buffers with new
            // dimensions. Dismiss any active session so the next
            // background auto-start opens at the right shape; the arm
            // below leaves the coordinator ready to do so.
            if isPiPActive {
                pipCoordinator.dismissIfActive()
            }
            armPiPIfReady()
        }
        layoutModel.scoreProvider = { [weak self] in self?.loadState.score }
    }

    private func wireTempoModel() {
        tempoModel.onChange = { [weak self] in
            guard let self else { return }
            await mutatePreferences { prefs in
                prefs.tempoMultiplier = self.tempoModel.multiplier
            }
        }
        tempoModel.controllerProvider = { [weak self] in self?.playbackController }
    }

    private func wireRepeatModel() {
        repeatModel.onChange = { [weak self] in
            guard let self else { return }
            await mutatePreferences { prefs in
                prefs.repeatMode = self.repeatModel.mode
                prefs.abRepeat = self.repeatModel.abRange
            }
        }
        repeatModel.scoreProvider = { [weak self] in self?.loadState.score }
        repeatModel.cursorProvider = { [weak self] in self?.playbackCursor }
        repeatModel.controllerProvider = { [weak self] in self?.playbackController }
    }

    /// Subscribe to the controller's cursor stream. Must be called from a
    /// view-lifecycle hook (`.task` / `.onAppear`) — NOT from `init` —
    /// so only the VM that SwiftUI actually retains via `@State` registers
    /// its handler. Calling from `init` regressed the playback cursor:
    /// SwiftUI re-evaluates the `@State(wrappedValue:)` expression on
    /// every parent body pass, constructing a fresh VM each time, but
    /// keeps only the first as the persisted state. The subsequent
    /// throwaway VMs all register handlers that capture themselves
    /// weakly, the last one wins, and once it's deallocated the engine's
    /// cursor changes land on a `[weak self]` that's already nil.
    func startObservingCursor() {
        guard let controller = playbackController else { return }
        controller.observeCursor { [weak self] value in
            guard let self else { return }
            rawPlaybackCursor = value
            playbackCursor = loadState.score?.translateCursorForHiddenStaves(
                value,
                hiddenStaves: layoutModel.hiddenStaves,
            ) ?? value
            notifyPiPCursor()
            // The engine emits a nil cursor only when playback hits the
            // end of the score (`PlaybackEngine.stop()` clears it; explicit
            // `pause()` does not). Use that signal to flip the toolbar's
            // play/pause glyph back to "play" — without this, isPlaying
            // stays true forever after the score finishes naturally.
            if value == nil, isPlaying {
                isPlaying = false
            }
        }
        // Mirror the engine's play/pause state into the VM regardless of
        // who flipped it (in-app toolbar, lock-screen Now Playing, audio
        // session interruption, etc.) so PiP chrome and toolbar glyph
        // stay accurate.
        controller.observeIsPlaying { [weak self] playing in
            self?.isPlaying = playing
        }
    }

    private func notifyPiPCursor() {
        pipCoordinatorBacking?.updatePlaybackCursor(playbackCursor)
    }

    func load() async {
        loadState = .loading
        let url = scoresDirectory.appending(path: scoreItem.localFileName)
        do {
            let (score, _) = try await gateway.loadScore(fileURL: url)
            await loadOrSeedPreferences()
            loadState = .loaded(score)
            armPiPIfReady()
            await updateLastOpenedAtOnce()
        } catch {
            let message = describe(error)
            loadState = .failed(message: message)
        }
    }

    /// Kick off the playback engine's `load` in the background as soon as
    /// the score is open, so the user usually finds soundfonts ready by
    /// the time they tap play. Idempotent — re-entry while a preload is
    /// in flight or already finished is a no-op.
    func prepareForPlayback() async {
        guard let controller = playbackController,
              case let .loaded(score) = loadState,
              !hasLoadedIntoPlayback,
              preloadTask == nil
        else { return }
        let prefs = PlaybackPreferences.initial(
            for: score,
            readerPreferences: preferences,
            scoreItemID: scoreItem.id,
            defaultVolume: Self.defaultStaffVolume,
        )
        let task = Task<Void, Error> { [scoreItem] in
            try await controller.load(
                score: score, displayTitle: scoreItem.title, preferences: prefs,
            )
        }
        preloadTask = task
        do {
            // Forward `.task` cancellation (user navigated away mid-prep)
            // into the unstructured load — without this hop the engine
            // load would keep running after the Reader disappears.
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            hasLoadedIntoPlayback = true
        } catch {
            // Cancellation or controller error — leave the slot clear so
            // a subsequent toggle starts a fresh attempt.
        }
        preloadTask = nil
    }

    func togglePlayback() async {
        guard let controller = playbackController,
              case let .loaded(score) = loadState,
              soundfontAlertKind == nil
        else { return }
        // If a silent prefetch is in flight (the user picked an instrument
        // while paused), wait for it before starting play. The mixer surfaces
        // its own alert copy during the wait.
        guard await mixerModel.awaitSilentPrefetch() else { return }
        if !hasLoadedIntoPlayback {
            let cached = await controller.areSoundfontsAvailableLocally(for: score)
            let online = await reachability?.isOnline() ?? true
            // Pick the alert copy based on what the wait will actually look
            // like to the user:
            //  - cache covers the score → no alert (load is just engine prep)
            //  - offline + cache miss   → "you're offline" (download won't progress)
            //  - online  + cache miss   → "loading playback sounds…"
            if !cached, !online {
                soundfontAlertKind = .offline
            } else if !cached {
                soundfontAlertKind = .loading
            }

            let prefs = PlaybackPreferences.initial(
                for: score,
                readerPreferences: preferences,
                scoreItemID: scoreItem.id,
                defaultVolume: Self.defaultStaffVolume,
            )
            let task = preloadTask ?? Task<Void, Error> { [scoreItem] in
                try await controller.load(
                    score: score, displayTitle: scoreItem.title, preferences: prefs,
                )
            }
            preloadTask = task
            do {
                try await task.value
                hasLoadedIntoPlayback = true
            } catch {
                soundfontAlertKind = nil
                preloadTask = nil
                return
            }
            soundfontAlertKind = nil
            preloadTask = nil
        }
        if isPlaying {
            await controller.pause()
            isPlaying = false
        } else {
            do {
                try await controller.play()
                isPlaying = true
            } catch {
                isPlaying = false
            }
        }
    }

    /// Cancels an in-flight `load` on the playback controller. Safe to call
    /// when no load is in flight — the cancel is a no-op.
    func cancelLoadingSoundfonts() {
        preloadTask?.cancel()
        mixerModel.cancelLoadingSoundfonts()
    }

    func resetZoom() {
        viewportZoom = 1.0
    }

    /// Records the current zoom as the value to restore on the next
    /// `toggleZoom`. Called from the gesture layer at the end of a pinch.
    func captureCurrentZoomAsLast() {
        if viewportZoom > 1.0 {
            lastNonUnitZoom = viewportZoom
        }
    }

    func toggleZoom(targetIfZoomedOut: CGFloat) {
        if viewportZoom > 1.0 {
            resetZoom()
        } else {
            viewportZoom = lastNonUnitZoom > 1.0 ? lastNonUnitZoom : targetIfZoomedOut
        }
    }

    func setManualCursor(_ cursor: ScoreCursor) {
        let engineCursor = loadState.score?.engineCursorForFilteredTap(
            cursor,
            hiddenStaves: layoutModel.hiddenStaves,
        ) ?? cursor
        rawPlaybackCursor = engineCursor
        playbackCursor = cursor
        guard let controller = playbackController else { return }
        Task { await controller.setCursor(to: engineCursor) }
    }

    // MARK: - Private

    private func loadOrSeedPreferences() async {
        do {
            if let stored = try await repository.loadReaderPreferences(for: scoreItem.id) {
                preferences = stored
                repeatModel.sync(from: stored)
                tempoModel.sync(from: stored)
                layoutModel.sync(from: stored)
                mixerModel.sync(from: stored)
                return
            }
        } catch {
            // Fall through and seed defaults; persistence error is non-fatal here.
        }
        let seeded = ReaderPreferences(
            scoreItemID: scoreItem.id,
            staffSize: defaultStaffSize,
            hiddenStaves: [],
        )
        preferences = seeded
        repeatModel.sync(from: seeded)
        tempoModel.sync(from: seeded)
        layoutModel.sync(from: seeded)
        mixerModel.sync(from: seeded)
        try? await repository.saveReaderPreferences(seeded)
    }

    private func mutatePreferences(_ apply: (inout ReaderPreferences) -> Void) async {
        var copy = preferences
        apply(&copy)
        // Re-seat through the initializer so clamping rules in
        // `ReaderPreferences.init` always run.
        let normalized = ReaderPreferences(
            id: copy.id,
            scoreItemID: copy.scoreItemID,
            staffSize: copy.staffSize,
            hiddenStaves: copy.hiddenStaves,
            staffProgramOverrides: copy.staffProgramOverrides,
            staffVolumeOverrides: copy.staffVolumeOverrides,
            staffClefOverrides: copy.staffClefOverrides,
            tempoMultiplier: copy.tempoMultiplier,
            honorLayoutBreaks: copy.honorLayoutBreaks,
            repeatMode: copy.repeatMode,
            abRepeat: copy.abRepeat,
        )
        preferences = normalized
        try? await repository.saveReaderPreferences(normalized)
    }

    private func updateLastOpenedAtOnce() async {
        guard !hasUpdatedLastOpened else { return }
        hasUpdatedLastOpened = true
        var updated = scoreItem
        updated.lastOpenedAt = Date()
        scoreItem = updated
        try? await repository.saveScoreItem(updated)
    }

    private func describe(_ error: Error) -> String {
        if let domain = error as? DomainError {
            switch domain {
            case .scoreFileNotFound:
                return String(localized: "reader.error.fileMissing", bundle: .module)
            case .scoreParseFailed:
                return String(localized: "reader.error.corrupted", bundle: .module)
            case .unsupportedFormat:
                return String(localized: "reader.error.cannotOpen.unsupportedType", bundle: .module)
            default:
                return domain.errorDescription ?? "\(domain)"
            }
        }
        return (error as NSError).localizedDescription
    }
}

// MARK: - PlaybackMixerHost conformance

extension ReaderViewModel: PlaybackMixerHost {
    func pausePlayback() async {
        guard let controller = playbackController, isPlaying else { return }
        await controller.pause()
        isPlaying = false
    }

    func tryResumePlayback() async {
        guard let controller = playbackController else { return }
        do {
            try await controller.play()
            isPlaying = true
        } catch {
            isPlaying = false
        }
    }

    func setSoundfontAlertKind(_ kind: SoundfontAlertKind?) {
        soundfontAlertKind = kind
    }
}
