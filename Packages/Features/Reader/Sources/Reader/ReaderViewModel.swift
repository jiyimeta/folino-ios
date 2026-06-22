import CoreGraphics
import Domain
import Foundation
import Observation
import ScoreUI
import SheetMusicCore

@MainActor
@Observable
final class ReaderViewModel {
    enum LoadState {
        case loading
        case loaded(Score)
        case failed(error: Error)

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
    var masterVolumeModel = MasterVolumeModel()
    var transposeModel = TransposeModel()
    var a4ReferenceModel = A4ReferenceModel()
    var layoutModel = LayoutSettingsModel()
    var mixerModel = PlaybackMixerModel()

    private(set) var loadState: LoadState = .loading

    /// The persisted annotation drawing for the current score, in document coordinates (M1 degenerate storage — one
    /// whole-canvas blob; M2 replaces this with per-stroke musical anchoring). The canvas seeds itself from this.
    var annotationDrawingData: Data?

    // Internal (not private) so `ReaderViewModel+AnnotationPersistence.swift` can reach them.
    @ObservationIgnored var annotationSaveTask: Task<Void, Never>?
    @ObservationIgnored var pendingAnnotationData: Data?
    @ObservationIgnored var pendingAnnotationIsEmpty = false

    /// The display-ready score: the loaded score with clef overrides applied, transposed, and hidden staves filtered.
    /// Cached and recomputed only when its inputs change (load, clef overrides, transpose, hidden staves) via
    /// `recomputeVisibleScore()`, so the transform chain no longer rebuilds on every Reader body evaluation.
    private(set) var visibleScore: Score?

    /// Internal (not private-set) so the ScoreInfoEditing conformance in a separate file can update it.
    var scoreItem: ScoreItem
    /// The playlist this Reader is traversing, or `nil` when opened standalone. Drives the inspector's continuation
    /// control and end-of-score auto-advance. The live ordered queue is re-derived from the repository on demand.
    @ObservationIgnored private let playlistID: PlaylistID?
    /// Persistence-of-record for `ReaderPreferences`. Sub-models observe their own state; this store is the
    /// single mutator and the source of truth for re-normalization.
    @ObservationIgnored private var preferencesStore: ReaderPreferencesStore

    /// Convenience accessor for imperative code paths that need the current preferences value (e.g. building
    /// `PlaybackPreferences.initial` at engine load time). Not observation-tracked — `preferencesStore` is
    /// `@ObservationIgnored` by design. Views observe the four sub-models, never `preferences` directly.
    var preferences: ReaderPreferences {
        preferencesStore.preferences
    }

    /// Whether the inspector should show the playlist-continuation control. True only when opened from a playlist.
    var isInPlaylist: Bool {
        playlistID != nil
    }

    var playbackSession: ReaderPlaybackSession
    var pipSession: ReaderPiPSession

    var viewportZoom: CGFloat = 1.0
    var isPlaybackInspectorPresented = false
    var isVisualInspectorPresented = false
    var isScoreInfoPresented = false
    var shareTarget: ScoreShareTarget?
    var isPreparingShare = false

    // `repository` / `metadataReader` are internal (not private) so the `ScoreInfoEditing` conformance can live in
    // ReaderViewModel+Conformances.swift; Swift `private` would not reach a same-type extension in another file.
    @ObservationIgnored let repository: any ScoreLibraryRepository
    @ObservationIgnored private let gateway: any ScoreFileGateway
    @ObservationIgnored private let shareService: any ScoreShareService
    @ObservationIgnored let metadataReader: any ScoreMetadataReading
    @ObservationIgnored let annotationStore: any AnnotationStore
    @ObservationIgnored private let scoresDirectory: URL
    @ObservationIgnored private let defaultStaffSize: Double
    @ObservationIgnored private var hasUpdatedLastOpened = false
    /// Re-entrancy guard for `advance`: the in-flight engine teardown/reload can deliver a spurious `cursor == nil`
    /// (→ `handlePlaybackReachedEnd`); this blocks a second advance mid-reload.
    @ObservationIgnored private var isAdvancing = false

    init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService = NoopScoreShareService(),
        metadataReader: any ScoreMetadataReading = NoopScoreMetadataReading(),
        annotationStore: any AnnotationStore = NoopAnnotationStore(),
        scoresDirectory: URL,
        defaultStaffSize: Double = 14,
        playbackController: (any PlaybackController)? = nil,
        museScoreGeneralProvider: (any MuseScoreGeneralProvider)? = nil,
        playlistID: PlaylistID? = nil,
    ) {
        self.scoreItem = scoreItem
        self.playlistID = playlistID
        self.repository = repository
        self.gateway = gateway
        self.shareService = shareService
        self.metadataReader = metadataReader
        self.annotationStore = annotationStore
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
        wireMasterVolumeModel()
        wireTransposeModel()
        wireA4ReferenceModel()
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
            transposeSemitones: transposeModel.semitones,
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
            recomputeVisibleScore()
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

    private func wireMasterVolumeModel() {
        masterVolumeModel.onChange = { [weak self] in
            guard let self else { return }
            await preferencesStore.mutate { prefs in
                prefs.masterVolume = self.masterVolumeModel.value
            }
        }
        masterVolumeModel.controllerProvider = { [weak self] in self?.playbackSession.controller }
    }

    private func wireTransposeModel() {
        transposeModel.onChange = { [weak self] in
            guard let self else { return }
            recomputeVisibleScore()
            await preferencesStore.mutate { prefs in
                prefs.transposeSemitones = self.transposeModel.semitones
            }
            pipSession.armIfReady()
        }
        transposeModel.controllerProvider = { [weak self] in self?.playbackSession.controller }
    }

    private func wireA4ReferenceModel() {
        a4ReferenceModel.onChange = { [weak self] in
            guard let self else { return }
            await preferencesStore.mutate { prefs in
                prefs.a4ReferenceHz = self.a4ReferenceModel.value
            }
        }
        a4ReferenceModel.controllerProvider = { [weak self] in self?.playbackSession.controller }
        a4ReferenceModel.globalDefaultProvider = {
            UserDefaults.standard.object(forKey: ReaderGlobalSettingsKey.a4ReferenceHz) as? Double
                ?? A4Reference.standardHz
        }
    }

    private func wireRepeatModel() {
        // The repeat *mode* is global (persisted by `RepeatModel` itself via `RepeatModeStorage`); only the per-score
        // A–B endpoints are saved here.
        repeatModel.onChange = { [weak self] in
            guard let self else { return }
            await preferencesStore.mutate { prefs in
                prefs.abRepeat = self.repeatModel.abRange
            }
        }
        repeatModel.scoreProvider = { [weak self] in self?.loadState.score }
        repeatModel.cursorProvider = { [weak self] in self?.playbackSession.playbackCursor }
        repeatModel.controllerProvider = { [weak self] in self?.playbackSession.controller }
        repeatModel.startObservingGlobalMode()
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
        playbackSession.onReachedEnd = { [weak self] in
            await self?.handlePlaybackReachedEnd()
        }
    }

    func load() async {
        loadState = .loading
        visibleScore = nil
        let url = scoresDirectory.appending(path: scoreItem.localFileName)
        do {
            let (score, _) = try await gateway.loadScore(fileURL: url)
            await loadOrSeedPreferences()
            loadState = .loaded(score)
            recomputeVisibleScore()
            pipSession.armIfReady()
            annotationDrawingData = nil
            await loadAnnotations()
            await updateLastOpenedAtOnce()
        } catch {
            loadState = .failed(error: error)
            visibleScore = nil
        }
    }

    func resetZoom() {
        viewportZoom = 1.0
    }

    func requestShare(format: ScoreShareFormat) async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await shareService.prepareShare(item: scoreItem, format: format)
            shareTarget = ScoreShareTarget(urls: [url])
        } catch {
            // Reader has no error banner yet; sharing failures are non-fatal and simply present nothing.
        }
    }

    /// Lazy format options for the share menu — same source as Library.
    func availableShareFormats() async -> [ScoreShareFormatOption] {
        await shareService.availableFormats(for: scoreItem)
    }

    // MARK: - Private

    /// The live, ordered `ScoreItemID`s of the playlist being traversed, filtered to items that still exist.
    /// Empty when standalone or when the playlist no longer exists.
    private func currentPlaylistQueue() -> [Domain.ScoreItemID] {
        guard let playlistID,
              let playlist = repository.playlists.first(where: { $0.id == playlistID })
        else { return [] }
        let liveIDs = Set(repository.scoreItems.map(\.id))
        return PlaylistPresentation.orderedLiveIDs(playlist, liveIDs: liveIDs)
    }

    /// Called when the engine reports end-of-score. Decides via `PlaylistPlaybackProgression` whether to advance to the
    /// next live playlist score and auto-play it. No-op when standalone, when the current score is no longer in the
    /// live queue, or when the decision is `.stop`.
    func handlePlaybackReachedEnd() async {
        guard !isAdvancing else { return }
        let queue = currentPlaylistQueue()
        guard let currentIndex = queue.firstIndex(of: scoreItem.id) else { return }
        let action = PlaylistPlaybackProgression.nextAction(
            currentIndex: currentIndex,
            count: queue.count,
            repeatMode: repeatModel.mode,
            continuation: PlaylistContinuationStorage.current(),
        )
        switch action {
        case .stop:
            return
        case let .advance(toIndex):
            guard let nextItem = repository.scoreItems.first(where: { $0.id == queue[toIndex] }) else { return }
            await advance(to: nextItem, autoPlay: true)
        }
    }

    /// Retarget this Reader to a different score *in place*: tear down the engine, swap the score item and its
    /// preferences store, reload the score + preferences (which re-syncs every sub-model), then optionally auto-play.
    /// The view and the shared `PlaybackController` (and its cursor observer) stay mounted across the swap.
    func advance(to newItem: ScoreItem, autoPlay: Bool) async {
        isAdvancing = true
        defer { isAdvancing = false }
        await flushPendingAnnotationSave()
        await playbackSession.releaseEngine()
        scoreItem = newItem
        preferencesStore = ReaderPreferencesStore(
            scoreItemID: newItem.id,
            defaultStaffSize: defaultStaffSize,
            repository: repository,
        )
        hasUpdatedLastOpened = false
        await load()
        await playbackSession.prepareForPlayback()
        // Re-seed the global metronome state into the freshly-loaded engine (mirrors ReaderRootScreen's `.task`).
        let metronomeEnabled = UserDefaults.standard.bool(forKey: ReaderGlobalSettingsKey.metronomeEnabled)
        await tempoModel.setMetronomeEnabled(metronomeEnabled)
        if autoPlay {
            await playbackSession.togglePlayback()
        }
    }

    /// Rebuild `visibleScore` from the loaded score and the current layout / transpose inputs. Cheap no-op when nothing
    /// is loaded. Called on load and from the layout / transpose change hooks, never from a view body.
    private func recomputeVisibleScore() {
        guard let score = loadState.score else {
            visibleScore = nil
            return
        }
        let withClefs = score.applying(clefOverrides: layoutModel.staffClefOverrides)
        // Transpose sits between clef overrides and the hidden-staves filter. It preserves note IDs and ticks, so the
        // playback cursor translation downstream is unaffected.
        let transposed = withClefs.transposed(bySemitones: transposeModel.semitones)
        visibleScore = transposed.filtered(hidingStaves: layoutModel.hiddenStaves)
    }

    private func loadOrSeedPreferences() async {
        let prefs = await preferencesStore.loadOrSeed()
        repeatModel.sync(from: prefs)
        tempoModel.sync(from: prefs)
        masterVolumeModel.sync(from: prefs)
        transposeModel.sync(from: prefs)
        a4ReferenceModel.sync(from: prefs)
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
}
