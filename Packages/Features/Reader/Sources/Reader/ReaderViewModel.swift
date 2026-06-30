import CoreGraphics
import Domain
import Foundation
import Observation
import PDFKit
import ScoreUI
import SheetMusicCore
import UtilityCore

@MainActor
@Observable
final class ReaderViewModel {
    enum LoadState {
        case loading
        case loaded(Score)
        case loadedPDF(PDFDocument)
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

    /// Settable (not `private(set)`) so the load paths in `ReaderViewModel+Load.swift` can drive the state transitions.
    var loadState: LoadState = .loading

    /// What this reader session is allowed to do, derived once per `load()` from the item's format (PDFs disable
    /// playback and all layout-derivation settings; only page/vertical viewing remains).
    private(set) var capabilities: ReaderCapabilities = .forScore

    /// The score's annotation model: one `DrawingAnchor` per stroke, each pinned to a `MusicalAnchor`. Loaded on open,
    /// rewritten on every canvas change. The container projects this to the current layout for display.
    var annotationDrawings: [DrawingAnchor] = []

    // Internal (not private) so `ReaderViewModel+AnnotationPersistence.swift` can reach them.
    @ObservationIgnored var annotationSaveTask: Task<Void, Never>?
    @ObservationIgnored var pendingAnnotationDrawings: [DrawingAnchor]?

    /// The display-ready score: the loaded score with clef overrides applied, transposed, and hidden staves filtered.
    /// Cached and recomputed only when its inputs change (load, clef overrides, transpose, hidden staves) via
    /// `recomputeVisibleScore()`, so the transform chain no longer rebuilds on every Reader body evaluation. Settable
    /// (not `private(set)`) so the load paths in `ReaderViewModel+Load.swift` can clear it on failure.
    var visibleScore: Score?

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
    var isAnnotating = false // true → canvas draws; false → all touches reach navigation + tap-to-seek
    /// Strokes committed since the current annotation session began. Flushed into `annotation_ended` on exit.
    @ObservationIgnored var annotationStrokeCount = 0
    /// Wall-clock start of the current annotation session, for `annotation_ended`'s `duration_sec`.
    @ObservationIgnored var annotationSessionStart: Date?
    var isPlaybackInspectorPresented = false
    var isVisualInspectorPresented = false
    var isScoreInfoPresented = false
    var shareTarget: ScoreShareTarget?
    var isPreparingShare = false

    // `repository` / `metadataReader` / `gateway` are internal (not private) so the `ScoreInfoEditing` conformance and
    // the `ReaderViewModel+Load.swift` load paths (same-type extensions in other files) can reach them; Swift `private`
    // would not.
    @ObservationIgnored let repository: any ScoreLibraryRepository
    @ObservationIgnored let gateway: any ScoreFileGateway
    // Internal so the share methods in `ReaderViewModel+Sharing.swift` can reach it.
    @ObservationIgnored let shareService: any ScoreShareService
    @ObservationIgnored let metadataReader: any ScoreMetadataReading
    @ObservationIgnored let annotationStore: any AnnotationStore
    @ObservationIgnored private let scoresDirectory: URL
    @ObservationIgnored private let defaultStaffSize: Double
    /// Internal so the transport / overlay / sharing view-layer log sites reach the same sink as the VM-owned events.
    @ObservationIgnored let analytics: any Analytics
    /// Origin surface the score was opened from, threaded from the Library navigation. Stamped onto `playback_started`
    /// so playback can be attributed to where the score was opened (mirrors Library's `select_content` `from`).
    /// Internal so the session-wiring extension can read it.
    @ObservationIgnored let openedFrom: AnalyticsSource
    /// The page/vertical/horizontal layout mode currently shown. Owned by `@AppStorage` in `ReaderRootScreen` (global,
    /// cross-score); mirrored here so `playback_started` can carry it. The root screen seeds and keeps this in sync.
    @ObservationIgnored var currentLayoutMode: ReaderLayoutMode = .page
    /// Baselines for deriving the increase/decrease and up/down direction of tempo / transpose changes. Seeded from the
    /// loaded preferences (so the first user edit compares against the persisted value), updated on each logged change.
    /// Internal so the analytics-direction helpers in `ReaderViewModel+Analytics.swift` can read / advance them.
    @ObservationIgnored var lastTempoMultiplier = 1.0
    @ObservationIgnored var lastTransposeSemitones = 0
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
        analytics: any Analytics = NoopAnalytics(),
        openedFrom: AnalyticsSource = .libraryAll,
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
        self.analytics = analytics
        self.openedFrom = openedFrom
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
            logTempoChangeIfNeeded()
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
            logTransposeChangeIfNeeded()
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
        // Fired only on a Reader-initiated mode change (the inspector picker or `setMode`), never on a sync from
        // persistence or an external Settings write — those reseed `mode` under `isSyncing`.
        repeatModel.onModeChanged = { [weak self] mode in
            self?.analytics.log(.repeatModeChanged(mode))
        }
        repeatModel.startObservingGlobalMode()
    }

    func load() async {
        loadState = .loading
        visibleScore = nil
        let format = ScoreFormat.detect(filename: scoreItem.localFileName)
        capabilities = ReaderCapabilities.resolve(format: format)
        let url = scoresDirectory.appending(path: scoreItem.localFileName)
        if format == .pdf {
            await loadPDF(url: url)
        } else {
            await loadScoreFile(url: url)
        }
    }

    func resetZoom() {
        viewportZoom = 1.0
    }

    // MARK: - Private

    /// The live, ordered `ScoreItemID`s of the playlist being traversed, filtered to items that still exist. Empty when
    /// standalone or when the playlist no longer exists. Internal so `ReaderViewModel+PlaylistNavigation` can reach it.
    func currentPlaylistQueue() -> [Domain.ScoreItemID] {
        guard let playlistID,
              let playlist = repository.playlists.first(where: { $0.id == playlistID })
        else { return [] }
        let liveIDs = Set(repository.scoreItems.map(\.id))
        return PlaylistPresentation.orderedLiveIDs(playlist, liveIDs: liveIDs)
    }

    /// Called when the engine reports end-of-score. Decides via `PlaylistPlaybackProgression` whether to advance to the
    /// next live playlist score and auto-play it. No-op when standalone, score no longer live, or decision is `.stop`.
    func handlePlaybackReachedEnd() async {
        guard !isAdvancing else { return }
        // Logged before the playlist/standalone branch so a standalone score (which returns at the queue guard below)
        // is counted too. The `isAdvancing` guard above keeps a spurious mid-reload nil-cursor from double-logging.
        analytics.log(.playbackCompleted())
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
    func recomputeVisibleScore() {
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

    /// Internal so both load paths in `ReaderViewModel+Load.swift` can reach the preference / last-opened helpers.
    func loadOrSeedPreferences() async {
        let prefs = await preferencesStore.loadOrSeed()
        repeatModel.sync(from: prefs)
        tempoModel.sync(from: prefs)
        masterVolumeModel.sync(from: prefs)
        transposeModel.sync(from: prefs)
        a4ReferenceModel.sync(from: prefs)
        layoutModel.sync(from: prefs)
        mixerModel.sync(from: prefs)
        // Seed the direction baselines from the loaded values so the first user edit compares against what's persisted
        // (and the sync itself logs nothing — `sync(from:)` bypasses the models' `onChange`).
        lastTempoMultiplier = tempoModel.effectiveMultiplier
        lastTransposeSemitones = transposeModel.semitones
    }

    func updateLastOpenedAtOnce() async {
        guard !hasUpdatedLastOpened else { return }
        hasUpdatedLastOpened = true
        var updated = scoreItem
        updated.lastOpenedAt = Date()
        scoreItem = updated
        try? await repository.saveScoreItem(updated)
    }
}
