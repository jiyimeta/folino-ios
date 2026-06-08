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
    var isScoreInfoPresented = false
    var shareTarget: ScoreShareTarget?
    var isPreparingShare = false

    @ObservationIgnored
    private let repository: any ScoreLibraryRepository
    @ObservationIgnored
    private let gateway: any ScoreFileGateway
    @ObservationIgnored
    private let shareService: any ScoreShareService
    @ObservationIgnored
    private let metadataReader: any ScoreMetadataReading
    @ObservationIgnored
    private let scoresDirectory: URL
    @ObservationIgnored
    private let defaultStaffSize: Double
    @ObservationIgnored
    private var hasUpdatedLastOpened = false

    init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService = NoopScoreShareService(),
        metadataReader: any ScoreMetadataReading = NoopScoreMetadataReading(),
        scoresDirectory: URL,
        defaultStaffSize: Double = 14,
        playbackController: (any PlaybackController)? = nil,
        museScoreGeneralProvider: (any MuseScoreGeneralProvider)? = nil,
    ) {
        self.scoreItem = scoreItem
        self.repository = repository
        self.gateway = gateway
        self.shareService = shareService
        self.metadataReader = metadataReader
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
            loadState = .failed(error: error)
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

// MARK: - PlaybackMixerHost conformance

extension ReaderViewModel: PlaybackMixerHost {
    /// Required by `PlaybackMixerHost`. Reads through `playbackSession` so `PlaybackMixerModel` can check whether
    /// playback is active (e.g. to decide whether to show a mute indicator).
    var isPlaying: Bool {
        playbackSession.isPlaying
    }

    /// Required by `PlaybackMixerHost`. Reads through `playbackSession` so `PlaybackMixerModel` can forward volume,
    /// mute, and program changes to the active controller without holding a direct reference to the session.
    var playbackController: (any PlaybackController)? {
        playbackSession.controller
    }
}

// MARK: - ScoreInfoEditing conformance

extension ReaderViewModel: ScoreInfoEditing {
    func loadFileMetadata(for item: ScoreItem) async -> ScoreFileMetadata? {
        try? await metadataReader.readMetadata(for: item)
    }

    func saveMetadata(_ item: ScoreItem, fields: EditableScoreInfo) async {
        let trimmedTitle = fields.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        var updated = item
        updated.title = trimmedTitle
        updated.subtitle = fields.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.composer = fields.composer.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.arranger = fields.arranger.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.lyricist = fields.lyricist.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.copyright = fields.copyright.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await repository.saveScoreItem(updated)
            scoreItem = updated
        } catch {
            // Non-fatal: keep the in-memory item; no Reader error banner yet.
        }
    }
}
