// swiftlint:disable file_length
import CoreGraphics
import Domain
import Foundation
import Observation
import SheetMusicCore

@MainActor
@Observable
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

    static let defaultStaffVolume = 1.0

    /// Always the same instance (set once at init); declared `var` only so `@Bindable` projections like
    /// `$viewModel.repeatModel.mode` type-check — the chain needs the intermediate path to be writable.
    var repeatModel = RepeatModel()
    var tempoModel = TempoModel()
    var layoutModel = LayoutSettingsModel()
    var mixerModel = PlaybackMixerModel()

    private(set) var loadState: LoadState = .loading
    private(set) var scoreItem: ScoreItem
    /// Persistence-of-record for `ReaderPreferences`. Sub-models observe their own state; this store is the
    /// single mutator and the source of truth for re-normalization.
    @ObservationIgnored private let preferencesStore: ReaderPreferencesStore

    /// Convenience accessor for imperative code paths that need the current preferences value (e.g. building
    /// `PlaybackPreferences.initial` at engine load time). Not observation-tracked — `preferencesStore` is
    /// `@ObservationIgnored` by design. Views observe the four sub-models, never `preferences` directly.
    var preferences: ReaderPreferences {
        preferencesStore.preferences
    }

    var playbackSession: ReaderPlaybackSession

    var viewportZoom: CGFloat = 1.0
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
        c.isAppPlayingProvider = { [weak self] in self?.playbackSession.isPlaying ?? false }
        c.onSetPlaying = { [weak self] desired in
            guard let self, playbackSession.isPlaying != desired else { return }
            Task { await self.playbackSession.togglePlayback() }
        }
        c.currentTimeProvider = { [weak self] in
            self?.playbackSession.controller?.currentTimeSeconds ?? 0
        }
        c.totalTimeProvider = { [weak self] in
            self?.playbackSession.controller?.totalTimeSeconds ?? 0
        }
        c.onSkip = { [weak self] seconds in
            guard let controller = self?.playbackSession.controller else { return }
            Task { await controller.skip(bySeconds: seconds) }
        }
        pipCoordinatorBacking = c
        return c
    }

    @ObservationIgnored
    private var isPiPEnabled = false
    @ObservationIgnored
    private var collapseMultiMeasureRests = false
    /// In-flight PiP rearm task. `armPiPIfReady` cancels this before spawning a new one so back-to-back triggers (e.g.
    /// the `onHiddenStavesChanged` → `onChange` pair fired by `toggleStaff`) collapse to a single arm against the
    /// latest state instead of queuing N detached `LayoutEngine.layout` runs.
    @ObservationIgnored
    private var pendingArmTask: Task<Void, Never>?
    /// True once `performPiPArm` has successfully attached a renderer in the current `isPiPEnabled` session. Cleared on
    /// disable so the next enable arms eagerly even without an active PiP or playback.
    @ObservationIgnored
    private var hasArmedPiP = false
    /// Set when `armPiPIfReady` postpones a rearm because no observer (active PiP or playing → imminent auto-start)
    /// would have seen the result. `flushPendingPiPArmIfDirty` consumes the flag when an observer appears (`isPlaying`
    /// flips true).
    @ObservationIgnored
    private var pipArmIsDirty = false

    /// Applies the user's Settings preference. Driven by the `readerPictureInPictureEnabled` `@AppStorage` value in
    /// `ReaderRootScreen`.
    func setPiPEnabled(_ enabled: Bool) {
        guard isPiPSupported else { return }
        isPiPEnabled = enabled
        applyPiPAutoStart()
        if enabled {
            armPiPIfReady()
        } else {
            pendingArmTask?.cancel()
            pendingArmTask = nil
            pipArmIsDirty = false
            hasArmedPiP = false
            pipCoordinator.dismissIfActive()
            pipCoordinator.disarm()
        }
    }

    /// Hands AVKit the current "may auto-present PiP on background" permission. We gate on `isPlaying` so PiP only
    /// appears when the user backgrounds *during playback* — matching YouTube's behavior. An already-presenting PiP
    /// session is left intact when playback pauses; only the auto-start permission is withdrawn.
    private func applyPiPAutoStart() {
        guard isPiPSupported else { return }
        pipCoordinator.setAutoStartFromBackground(isPiPEnabled && playbackSession.isPlaying)
    }

    func setCollapseMultiMeasureRests(_ enabled: Bool) {
        guard collapseMultiMeasureRests != enabled else { return }
        collapseMultiMeasureRests = enabled
        // Re-arm PiP immediately so a currently-armed session re-lays out with the new policy. No-op when PiP is
        // disabled or the score hasn't finished loading — `armPiPIfReady` guards both.
        armPiPIfReady()
    }

    /// Called from `ReaderRootScreen`'s `scenePhase` observer when the app returns to the foreground — the Settings
    /// spec dismisses PiP on return regardless of why it started.
    func dismissPiPOnForeground() {
        guard isPiPActive else { return }
        pipCoordinator.dismissIfActive()
    }

    /// Coalesced rearm trigger. The heavy layout step inside `pipCoordinator.arm` runs off the main actor, but it's
    /// still wasted CPU when no observer would see the result — the user is paused in the foreground and PiP isn't
    /// visible. In that case the arm is postponed; `flushPendingPiPArmIfDirty` consumes the postponement when an
    /// observer appears.
    ///
    /// The first arm of each `isPiPEnabled` session always proceeds so a manual PiP start (via the system control)
    /// still finds a renderer attached.
    private func armPiPIfReady() {
        guard isPiPEnabled, case .loaded = loadState else { return }
        if !hasArmedPiP || isPiPActive || playbackSession.isPlaying {
            scheduleArm()
        } else {
            pipArmIsDirty = true
        }
    }

    private func scheduleArm() {
        pipArmIsDirty = false
        pendingArmTask?.cancel()
        pendingArmTask = Task { [weak self] in
            guard let self else { return }
            await performPiPArm()
        }
    }

    private func flushPendingPiPArmIfDirty() {
        guard pipArmIsDirty else { return }
        scheduleArm()
    }

    private func performPiPArm() async {
        guard !Task.isCancelled,
              isPiPEnabled,
              case let .loaded(score) = loadState
        else { return }
        // Mirror the on-screen transformation so the PiP view sees the same staves and clefs as the main Reader pane.
        let visible = score
            .applying(clefOverrides: layoutModel.staffClefOverrides)
            .filtered(hidingStaves: layoutModel.hiddenStaves)
        do {
            try await pipCoordinator.arm(
                score: visible,
                staffSize: layoutModel.staffSize,
                playbackCursor: playbackSession.playbackCursor,
                collapseMultiMeasureRests: collapseMultiMeasureRests,
            )
            hasArmedPiP = true
        } catch is CancellationError {
            // Superseded by a newer rearm; nothing to do.
        } catch {
            // Coordinator throws only when no display layer is attached (the host view hasn't mounted yet). Arming will
            // retry once the view installs the layer and load() finishes — neither ordering is fatal.
        }
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
    private var hasUpdatedLastOpened = false

    init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL,
        defaultStaffSize: CGFloat = 14,
        playbackController: (any PlaybackController)? = nil,
        museScoreGeneralProvider: (any MuseScoreGeneralProvider)? = nil,
    ) {
        self.scoreItem = scoreItem
        self.repository = repository
        self.gateway = gateway
        self.scoresDirectory = scoresDirectory
        self.defaultStaffSize = defaultStaffSize
        preferencesStore = ReaderPreferencesStore(
            scoreItemID: scoreItem.id,
            defaultStaffSize: defaultStaffSize,
            repository: repository,
        )
        playbackSession = ReaderPlaybackSession(
            controller: playbackController,
            museScoreGeneralProvider: museScoreGeneralProvider,
        )
        wireRepeatModel()
        wireTempoModel()
        wireLayoutModel()
        wireMixerModel()
        wirePlaybackSession()
    }

    private func wireMixerModel() {
        mixerModel.host = self
        mixerModel.onChange = { [weak self] in
            guard let self else { return }
            await preferencesStore.mutate { prefs in
                prefs.staffProgramOverrides = self.mixerModel.staffProgramOverrides
                prefs.staffVolumeOverrides = self.mixerModel.staffVolumeOverrides
            }
        }
    }

    private func wireLayoutModel() {
        layoutModel.onChange = { [weak self] in
            guard let self else { return }
            await preferencesStore.mutate { prefs in
                prefs.staffSize = self.layoutModel.staffSize
                prefs.honorLayoutBreaks = self.layoutModel.honorLayoutBreaks
                prefs.hiddenStaves = self.layoutModel.hiddenStaves
                prefs.staffClefOverrides = self.layoutModel.staffClefOverrides
            }
            // Clef override edits land only through this path (hidden-staves changes also fire
            // `onHiddenStavesChanged`), so rebuild the PiP renderer here to pick them up.
            armPiPIfReady()
        }
        layoutModel.onHiddenStavesChanged = { [weak self] in
            guard let self else { return }
            playbackSession.refreshTranslation()
            // PiP dismiss-on-layout-change moves into Task 3's wiring; keep the existing inline call so
            // behavior is identical mid-extraction.
            if isPiPActive {
                pipCoordinator.dismissIfActive()
            }
        }
        layoutModel.scoreProvider = { [weak self] in self?.loadState.score }
    }

    private func wireTempoModel() {
        tempoModel.onChange = { [weak self] in
            guard let self else { return }
            await preferencesStore.mutate { prefs in
                prefs.tempoMultiplier = self.tempoModel.multiplier
            }
        }
        tempoModel.controllerProvider = { [weak self] in self?.playbackSession.controller }
    }

    private func wireRepeatModel() {
        repeatModel.onChange = { [weak self] in
            guard let self else { return }
            await preferencesStore.mutate { prefs in
                prefs.repeatMode = self.repeatModel.mode
                prefs.abRepeat = self.repeatModel.abRange
            }
        }
        repeatModel.scoreProvider = { [weak self] in self?.loadState.score }
        repeatModel.cursorProvider = { [weak self] in self?.playbackSession.playbackCursor }
        repeatModel.controllerProvider = { [weak self] in self?.playbackSession.controller }
    }

    private func wirePlaybackSession() {
        playbackSession.scoreProvider = { [weak self] in self?.loadState.score }
        playbackSession.hiddenStavesProvider = { [weak self] in self?.layoutModel.hiddenStaves ?? [] }
        playbackSession.preferencesProvider = { [weak self] in self?.preferencesStore.preferences }
        playbackSession.scoreItemProvider = { [weak self] in self?.scoreItem }
        playbackSession.onPlayingChanged = { [weak self] playing in
            guard let self else { return }
            applyPiPAutoStart()
            if playing { flushPendingPiPArmIfDirty() }
        }
        playbackSession.onCursorChanged = { [weak self] in
            self?.pipCoordinatorBacking?.updatePlaybackCursor(self?.playbackSession.playbackCursor)
        }
        playbackSession.onReadyForLoopForward = { [weak self] in
            await self?.repeatModel.forwardLoopRangeToController()
        }
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

    func resetZoom() {
        viewportZoom = 1.0
    }

    // MARK: - Private

    private func loadOrSeedPreferences() async {
        let prefs = await preferencesStore.loadOrSeed()
        repeatModel.sync(from: prefs)
        tempoModel.sync(from: prefs)
        layoutModel.sync(from: prefs)
        mixerModel.sync(from: prefs)
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

    // MARK: - Temporary forwarders (deleted in Task 4)

    var isPlaying: Bool {
        playbackSession.isPlaying
    }

    var playbackCursor: ScoreCursor? {
        playbackSession.playbackCursor
    }

    var playbackController: (any PlaybackController)? {
        playbackSession.controller
    }

    func prepareForPlayback() async {
        await playbackSession.prepareForPlayback()
    }

    func releaseEngine() async {
        await playbackSession.releaseEngine()
    }

    func togglePlayback() async {
        await playbackSession.togglePlayback()
    }

    func startObservingCursor() {
        playbackSession.startObservingCursor()
    }

    func startObservingSoundfontDownload() {
        playbackSession.startObservingSoundfontDownload()
    }

    func setManualCursor(_ cursor: ScoreCursor) {
        playbackSession.setManualCursor(cursor)
    }
}

// MARK: - PlaybackMixerHost conformance

extension ReaderViewModel: PlaybackMixerHost {}
