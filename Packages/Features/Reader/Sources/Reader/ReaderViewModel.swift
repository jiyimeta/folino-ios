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
    var pipSession: ReaderPiPSession

    var viewportZoom: CGFloat = 1.0
    var isPlaybackInspectorPresented = false
    var isVisualInspectorPresented = false

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
        pipSession = ReaderPiPSession()
        wireRepeatModel()
        wireTempoModel()
        wireLayoutModel()
        wireMixerModel()
        wirePlaybackSession()
        wirePiPSession()
    }

    private func wirePiPSession() {
        pipSession.scoreProvider = { [weak self] in self?.loadState.score }
        pipSession.isPlayingProvider = { [weak self] in self?.playbackSession.isPlaying ?? false }
        pipSession.playbackCursorProvider = { [weak self] in self?.playbackSession.playbackCursor }
        pipSession.layoutSnapshotProvider = { [weak self] in self?.currentPiPLayoutSnapshot() }
        pipSession.playbackController = playbackSession.controller
        pipSession.onTogglePlayback = { [weak self] in await self?.playbackSession.togglePlayback() }
    }

    private func currentPiPLayoutSnapshot() -> PiPLayoutSnapshot {
        PiPLayoutSnapshot(
            staffSize: layoutModel.staffSize,
            hiddenStaves: layoutModel.hiddenStaves,
            clefOverrides: layoutModel.staffClefOverrides,
        )
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
            pipSession.armIfReady()
        }
        layoutModel.onHiddenStavesChanged = { [weak self] in
            guard let self else { return }
            playbackSession.refreshTranslation()
            pipSession.dismissIfActive()
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
            self?.pipSession.onPlayingChanged(to: playing)
        }
        playbackSession.onCursorChanged = { [weak self] in
            self?.pipSession.notifyCursorChanged()
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
            pipSession.armIfReady()
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

    var isPiPSupported: Bool {
        ReaderPiPSession.isSupported
    }

    var isPiPActive: Bool {
        pipSession.isActive
    }

    func setPiPEnabled(_ enabled: Bool) {
        pipSession.setEnabled(enabled)
    }

    func setCollapseMultiMeasureRests(_ enabled: Bool) {
        pipSession.setCollapseMultiMeasureRests(enabled)
    }

    func dismissPiPOnForeground() {
        pipSession.dismissIfActive()
    }
}

// MARK: - PlaybackMixerHost conformance

extension ReaderViewModel: PlaybackMixerHost {}
