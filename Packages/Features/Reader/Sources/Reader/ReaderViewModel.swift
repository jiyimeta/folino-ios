// swiftlint:disable file_length
// ReaderViewModel owns the whole Reader session: load state, every sub-model (repeat/tempo/volume/transpose/layout/
// mixer), playback + PiP session wiring, playlist advance, and now the note-editing score-adoption reload path
// (`adoptEditedScore`); that breadth keeps it just over the file_length budget.

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
            if case let .loaded(score) = self {
                return score
            }
            return nil
        }

        /// Whether a parsed score is on screen. An `Equatable` projection of a state that isn't: the Mac reader
        /// watches it with `onChange` to reopen the editing session after a revert's reload lands.
        var isLoaded: Bool {
            if case .loaded = self {
                true
            } else {
                false
            }
        }
    }

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

    /// What this reader session is allowed to do, derived per `load()` from the item's format and what is currently on
    /// screen: a fixed-layout PDF page can't be re-engraved, so it disables every layout-derivation setting.
    /// Settable (not `private(set)`) so the display-source switch in `ReaderViewModel+DisplaySource.swift` can swap it.
    var capabilities: ReaderCapabilities = .forScore

    /// Which rendition is on screen. Only an item whose PDF has been read into notation can be on `.originalPDF` by
    /// choice; one folino couldn't read is pinned there because there is nothing else to show.
    /// Settable (not `private(set)`) so the load and display-source paths in the extensions can drive it.
    var displaySource: ReaderDisplaySource = .score

    /// The original PDF, opened lazily on the first switch to `.originalPDF` — a session that never switches never
    /// pays for it. Always `nil` for an item that never came from a PDF.
    var originalPDFDocument: PDFDocument?

    /// The layout mode the score side was on before switching to the original, so coming back doesn't silently demote
    /// the user's choice. Only horizontal is ever remembered — page and vertical exist on both sides and round-trip
    /// untouched. Owned here rather than in the view because the switch outlives any one body evaluation.
    var savedScoreLayoutMode: ReaderLayoutMode?

    /// Background OMR-playback readiness for an opened PDF. The PDF is displayed immediately
    /// (`loadState == .loadedPDF`); in parallel it's parsed into a playable `Score` + on-PDF geometry.
    /// Settable (not `private(set)`) so the PDF load path in `ReaderViewModel+Load.swift` and the parse
    /// method in `ReaderViewModel+PDFPlayback.swift` can drive the transitions.
    var pdfPlayback: PDFPlaybackState = .idle

    /// True while a PDF is being read into notation — either on open (an item imported before folino could read one)
    /// or on an explicit re-read. The reader shows its loading state for the duration; OMR is slow enough to notice.
    /// Settable (not `private(set)`) so `ReaderViewModel+PDFConversion.swift` can drive it.
    var isConvertingPDF = false

    /// Set when a re-read fails, so the root screen can say so and clear it. Nothing else changes on failure.
    var reReadError: String?

    /// The score's annotation model: one `DrawingAnchor` per stroke, each pinned to a `MusicalAnchor`. Loaded on open,
    /// rewritten on every canvas change. The container projects this to the current layout for display.
    var annotationDrawings: [DrawingAnchor] = []

    /// Handle to the latest `drawingsDidChange` hop onto the coordinator, awaited by `flushPendingAnnotationSave`.
    @ObservationIgnored var annotationChangeTask: Task<Void, Never>?

    /// Raised when a part-remap re-seed could not read the annotation layer back, and lowered by the next read that
    /// can. While it stands the ink writer refuses every capture: the model is holding pre-migration anchors that the
    /// stored layer no longer agrees with, and the mapping has been consumed, so a write would make that permanent.
    ///
    /// Deliberately NOT the shared `isPartMigrationPending` hold — that one also gates the preferences writer, and
    /// leaving it raised to cover this would strand that writer for the rest of the session.
    @ObservationIgnored var isInkReseedPending = false

    /// Bumped whenever `annotationDrawings` is replaced WHOLESALE from the store rather than by the user's own ink —
    /// today, the part-index re-seed. The score containers reproject the canvas on it.
    ///
    /// A ticket rather than observing `annotationDrawings` directly, which the containers deliberately do not: while
    /// the user draws, the canvas is the source of truth, and re-seeding it with the round-tripped projection would
    /// wipe the just-committed stroke (see the comment on `VerticalScoreContainer`'s `.onChange(of: document)`). This
    /// fires only on the one path where the model really has moved under the canvas and the canvas is wrong.
    var annotationReseedTicket = 0

    /// The display-ready score: the loaded score with clef overrides applied, transposed, and hidden staves filtered.
    /// Cached and recomputed only when its inputs change (load, clef overrides, transpose, hidden staves) via
    /// `recomputeVisibleScore()`, so the transform chain no longer rebuilds on every Reader body evaluation. Settable
    /// (not `private(set)`) so the load paths in `ReaderViewModel+Load.swift` can clear it on failure.
    var visibleScore: Score?

    /// The seek card's cached score-derived inputs (rehearsal marks + notated duration), the same recompute-at-the-
    /// choke-points pattern as `visibleScore`. Rebuilt by `recomputeSeekTimeline()` on load, edited-score adoption,
    /// and a PDF parse landing — never from a view body, because both derivations walk the entire score (see
    /// `ReaderSeekTimeline`) and the transport card's body runs every frame during the mode-swipe morph.
    private(set) var seekTimeline: ReaderSeekTimeline = .empty

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

    /// Forwards to the preferences store for the extensions that live in other files (`preferencesStore` itself stays
    /// private so the sub-models keep going through their own wiring).
    func mutatePreferences(_ apply: @escaping (inout ReaderPreferences) -> Void) async {
        await preferencesStore.mutate(apply)
    }

    /// Same forwarding as `mutatePreferences`, for the part-remap reload in `ReaderViewModel+PartRemap.swift`: joins
    /// every preference write started elsewhere, so re-reading the row can't race one that is still in the air.
    func flushPendingPreferenceWrites() async {
        await preferencesStore.flushPendingWrites()
    }

    /// Lets the writes the store held while a part-index migration was in flight go through, against the row as it
    /// stands after the reload. See `ReaderPreferencesStore.applyDeferredMutations`.
    func applyDeferredPreferenceWrites() async {
        await preferencesStore.applyDeferredMutations()
    }

    /// Drops them instead, for the reload path that has no migrated row to re-run them against.
    func discardDeferredPreferenceWrites() {
        preferencesStore.discardDeferredMutations()
    }

    /// Wires the hold to whatever the caller knows about the Editor's unsettled part edits. Called by the editing-seam
    /// wiring, once; a Reader with no editing host never holds.
    ///
    /// It governs BOTH of this process's part-indexed writers — the preferences row and the annotation layer. They
    /// hold for the same reason and for exactly the same window, and one provider is what keeps them from disagreeing
    /// about whether it is up.
    func setPartMigrationPendingProvider(_ provider: @escaping @MainActor () -> Bool) {
        isPartMigrationPending = provider
        preferencesStore.isMigrationPending = provider
    }

    /// Whether a part edit's migration is still unsettled — see `setPartMigrationPendingProvider`. Read by
    /// `annotationDrawingsDidChange`; the preferences store holds its own copy.
    @ObservationIgnored var isPartMigrationPending: @MainActor () -> Bool = { false }

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

    /// `repository` / `metadataReader` / `gateway` are internal (not private) so the `ScoreInfoEditing` conformance
    /// and the `ReaderViewModel+Load.swift` load paths (same-type extensions in other files) can reach them; Swift
    /// `private` would not.
    @ObservationIgnored let repository: any ScoreLibraryRepository
    /// Internal so `ReaderViewModel+PDFReread.swift` can discard the captured original on re-read.
    @ObservationIgnored let originalStore: any ScoreOriginalStore
    @ObservationIgnored let gateway: any ScoreFileGateway
    /// Internal so the share methods in `ReaderViewModel+Sharing.swift` can reach it.
    @ObservationIgnored let shareService: any ScoreShareService
    /// Internal so `requestVocalTunerHandoff` in `ReaderViewModel+Sharing.swift` can reach it.
    @ObservationIgnored let vocalTunerHandoff: any VocalTunerHandoff
    @ObservationIgnored let metadataReader: any ScoreMetadataReading
    /// The shared annotation save policy (debounce + empty→delete + assembly), reused by iOS and Android.
    @ObservationIgnored let annotationCoordinator: AnnotationSaveCoordinator
    /// Optional PDF → playable-score parser. `nil` on platforms / builds without ssm's PDF importer;
    /// when present, `loadPDF` parses the opened PDF in the background to enable playback + the on-PDF
    /// cursor. Internal so the PDF load path in `ReaderViewModel+Load.swift` can reach it.
    @ObservationIgnored let pdfPlaybackParser: (any PDFPlaybackParser)?
    /// Reads a PDF into notation and writes it as `.mscz`. Injected by the App (`nil` on builds without ssm's PDF
    /// importer). Drives both the one-time conversion of a PDF imported before folino could read one and the explicit
    /// re-read. Internal so the conversion extension can reach it.
    @ObservationIgnored let pdfConversion: PDFScoreConversion?
    /// Internal so `ReaderViewModel+PDFConversion.swift` can resolve sidecar / destination paths.
    @ObservationIgnored let scoresDirectory: URL
    @ObservationIgnored private let defaultStaffSize: Double
    @ObservationIgnored private let defaultHonorLayoutBreaks: Bool
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
        originalStore: any ScoreOriginalStore = NoopScoreOriginalStore(),
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService = NoopScoreShareService(),
        vocalTunerHandoff: any VocalTunerHandoff = NoopVocalTunerHandoff(),
        metadataReader: any ScoreMetadataReading = NoopScoreMetadataReading(),
        annotationCoordinator: AnnotationSaveCoordinator = AnnotationSaveCoordinator(store: NoopAnnotationBlobStore()),
        scoresDirectory: URL,
        defaultStaffSize: Double = 12,
        defaultHonorLayoutBreaks: Bool = false,
        playbackController: (any PlaybackController)? = nil,
        pdfPlaybackParser: (any PDFPlaybackParser)? = nil,
        pdfConversion: PDFScoreConversion? = nil,
        museScoreGeneralProvider: (any MuseScoreGeneralProvider)? = nil,
        playlistID: PlaylistID? = nil,
        analytics: any Analytics = NoopAnalytics(),
        openedFrom: AnalyticsSource = .libraryAll,
    ) {
        self.scoreItem = scoreItem
        self.playlistID = playlistID
        self.repository = repository
        self.originalStore = originalStore
        self.gateway = gateway
        self.shareService = shareService
        self.vocalTunerHandoff = vocalTunerHandoff
        self.metadataReader = metadataReader
        self.annotationCoordinator = annotationCoordinator
        self.pdfPlaybackParser = pdfPlaybackParser
        self.pdfConversion = pdfConversion
        self.scoresDirectory = scoresDirectory
        self.defaultStaffSize = defaultStaffSize
        self.defaultHonorLayoutBreaks = defaultHonorLayoutBreaks
        self.analytics = analytics
        self.openedFrom = openedFrom
        preferencesStore = ReaderPreferencesStore(
            scoreItemID: scoreItem.id,
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
                prefs.stripProgramOverrides = self.mixerModel.programOverrides
                prefs.stripVolumeOverrides = self.mixerModel.volumeOverrides
            }
        }
    }

    private func wireLayoutModel() {
        layoutModel.defaultStaffSize = defaultStaffSize
        layoutModel.defaultHonorLayoutBreaks = defaultHonorLayoutBreaks
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
        // A–B endpoints are saved here, and they snap against `playbackScore` (a playable PDF's parsed score too).
        repeatModel.onChange = { [weak self] in
            guard let self else { return }
            await preferencesStore.mutate { prefs in
                prefs.abRepeat = self.repeatModel.abRange
            }
        }
        repeatModel.scoreProvider = { [weak self] in self?.playbackScore }
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
        capabilities = ReaderCapabilities.resolve(format: format, displaySource: displaySource)
        let url = scoresDirectory.appending(path: scoreItem.localFileName)
        guard format == .pdf else {
            await loadScoreFile(url: url)
            return
        }
        // A PDF imported before folino could read one converts here, on its first open, and lands in the normal score
        // path from then on. One that can't be read keeps today's behavior exactly.
        if let scoreURL = await convertPDFIfNeeded(url: url) {
            capabilities = ReaderCapabilities.resolve(format: .mscz, displaySource: displaySource)
            await loadScoreFile(url: scoreURL)
        } else {
            await loadPDF(url: url)
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

    /// Adopt the edited score as the loaded score and re-prepare the audio engine against it (the engine's sequencer
    /// still holds the pre-edit score). Mirrors the `advance(to:)` reload sequence without swapping the item — the
    /// score item, preferences store, and playlist context are all unchanged; only the note content is new.
    func adoptEditedScore(_ score: Score) async {
        loadState = .loaded(score)
        recomputeVisibleScore()
        recomputeSeekTimeline()
        await playbackSession.releaseEngine()
        await playbackSession.prepareForPlayback()
        pipSession.armIfReady()
    }

    /// The editor's live score while an edit session is open, or `nil` outside one. Wired by `ReaderRootScreen`,
    /// which is the only thing holding both the host and this view model.
    @ObservationIgnored var editedScoreProvider: @MainActor () -> Score? = { nil }

    /// The transport's way in: catch the engine up with whatever has been edited since it last loaded.
    ///
    /// This is what makes playback mid-session hear the notes just written. Before it, `adoptEditedScore` ran only at
    /// `finishEditing()`, so everything played during a session was the score as it stood when the session opened.
    ///
    /// Whether there is anything to do is decided by COMPARING the two scores rather than by a flag the editor
    /// raises. A flag would have to be lowered by every adoption and not raised by the seeding write `startEditing`
    /// makes with the score already loaded — two ways to drift out of step, in exchange for saving one `==` on a
    /// tap that is about to rebuild the audio engine anyway.
    func adoptEditedScoreForPlaybackIfStale() async {
        guard let edited = editedScoreProvider(), edited != loadState.score else { return }
        await adoptEditedScore(edited)
    }

    /// Rebuild `visibleScore` from the loaded score and the current layout / transpose inputs. Cheap no-op when nothing
    /// is loaded. Called on load and from the layout / transpose change hooks, never from a view body.
    func recomputeVisibleScore() {
        guard let score = loadState.score else {
            visibleScore = nil
            return
        }
        // Clef overrides → written-pitch view → transpose → hidden staves. The order and why every step is safe for
        // the playback cursor are documented on `ReaderDisplayTransforms`, which PiP and the editing page share.
        // PARITY(android): M2 written-pitch view — Android's render pipeline still needs writtenPitchView() between
        //   clef overrides and transpose
        visibleScore = ReaderDisplayTransforms.display(
            score,
            clefOverrides: layoutModel.staffClefOverrides,
            transposeSemitones: transposeModel.effectiveSemitones,
            hiddenStaves: layoutModel.hiddenStaves,
        )
    }

    /// Rebuild `seekTimeline` from the score the transport drives — the loaded score, or a playable PDF's parsed
    /// score (the same precedence as the transport control's `transportScore`). Called from `loadScoreFile` and
    /// `adoptEditedScore` (which cover every `.loaded` transition, including playlist advance) and from the PDF
    /// parse landing in `parsePDFForPlayback`. Marks and duration only depend on measure structure and tempo, so
    /// the layout / transpose hooks that rebuild `visibleScore` don't need to touch this.
    func recomputeSeekTimeline() {
        let score = loadState.score ?? (isPDFPlaybackReady ? playbackScore : nil)
        guard let score else {
            seekTimeline = .empty
            return
        }
        seekTimeline = ReaderSeekTimeline(score: score)
    }

    /// Reachable from both load paths; `authoredHiddenStaves` (empty for PDFs) are seeded in `loadOrSeed`.
    ///
    /// A `nil` answer means the LOAD failed (not that there is no row): the sub-models keep whatever they hold
    /// rather than being re-seeded from a value that was never read. On the part-remap reload path that is what
    /// stops one unlucky read from distributing defaults over a just-migrated row.
    @discardableResult
    func loadOrSeedPreferences(authoredHiddenStaves: Set<StaffAddress> = []) async -> Bool {
        guard let prefs = await preferencesStore.loadOrSeed(
            authoredHiddenStaves: authoredHiddenStaves,
        ) else { return false }
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
        lastTransposeSemitones = transposeModel.effectiveSemitones
        return true
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
