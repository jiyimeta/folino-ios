// PARITY(macos): the Mac reading surface's chrome — this screen renders the score in Page or Vertical mode and lets
//   it scroll, and nothing else. The transport, the inspectors, the share / annotate / edit controls, Horizontal
//   layout mode, and the original-PDF renditions are all still iOS-only; see `ReaderRootScreen` for the surface being
//   caught up to.

#if os(macOS)
import Domain
import SheetMusicCore
import SwiftUI
import UtilityCore

/// The Mac Reader's root: it builds the shared `ReaderViewModel` exactly as `ReaderRootScreen` does, drives its
/// lifecycle, and hosts the vertical score container.
///
/// **This is a sibling of `ReaderRootScreen`, not a port of it.** The view model and every sub-model are shared
/// as-is; the screen is not, because roughly half of the iOS one is physics that has no meaning here — the self-drawn
/// top strip and its cutout tier, the status-bar handoff, `hostingAppearance(.light)`, the idle timer, the PiP host,
/// and the interactive-pop-gesture restoration. None of that comes across, so the two screens diverge rather than
/// growing a seam of `#if`s down the middle of an 800-line file.
///
/// What it deliberately does NOT do yet, each owned by a later task: the transport control, the inspectors, the
/// note-editing seam (`ReaderEditingHost`), Page / Horizontal layout modes, and the original-PDF renditions.
@MainActor
public struct MacReaderRootScreen: View {
    @State private var viewModel: ReaderViewModel

    /// The same preference the iOS reader writes (`View ▸ Display Mode` on the Mac, the visual inspector's segmented
    /// control on iOS), so a score agrees with itself about what mode it is in wherever it is opened.
    @AppStorage(ReaderGlobalSettingsKey.layoutMode)
    private var layoutModeRaw: String = ReaderLayoutMode.page.rawValue

    @AppStorage(ReaderGlobalSettingsKey.metronomeEnabled)
    private var isMetronomeEnabled = false

    @AppStorage(ReaderGlobalSettingsKey.collapseMultiMeasureRests)
    private var collapseMultiMeasureRests = false

    @AppStorage(ReaderGlobalSettingsKey.showInvisibleElements)
    private var showInvisibleElements = false

    @AppStorage(ReaderGlobalSettingsKey.showAllMeasureNumbers)
    private var showAllMeasureNumbers = false

    @AppStorage(ReaderGlobalSettingsKey.autoFollowEnabled)
    private var autoFollowEnabled = true

    /// `ReaderRootScreen`'s initializer minus every argument that only an iOS surface can honor: the editing seam
    /// (`editingHost` / `editingChrome` / `editingTopBar` / `editingCutoutTier` / `startInEditMode`), the navigation
    /// callbacks (`onBack` / `onToggleSidebar` — the Mac's sidebar belongs to `NavigationSplitView`), the status-bar
    /// handoff, the screenshot override, and the VocalTuner handoff (a URL-scheme jump to an iOS sibling app).
    ///
    /// `playbackController` is `nil` on macOS today — `AudioStackFactory` has no Mac `LivePlaybackController` yet — so
    /// the whole playback surface is inert rather than absent: `ReaderPlaybackSession` guards every controller call.
    public init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        originalStore: any ScoreOriginalStore,
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService,
        metadataReader: any ScoreMetadataReading,
        annotationCoordinator: AnnotationSaveCoordinator,
        scoresDirectory: URL,
        playbackController: (any PlaybackController)? = nil,
        analytics: any Analytics = NoopAnalytics(),
    ) {
        // The Mac takes the iPad's pair of untouched-preference defaults: a Mac window is a large screen, so the
        // roomier staff size and the engraver's authored break boundaries are the right starting point. Same call the
        // iOS screen makes through `ReaderDeviceDefaults.staffSize` / `.honorLayoutBreaks`, with the idiom decision
        // supplied here because there is no `UIDevice` to ask.
        _viewModel = State(
            wrappedValue: ReaderViewModel(
                scoreItem: scoreItem,
                repository: repository,
                originalStore: originalStore,
                gateway: gateway,
                shareService: shareService,
                metadataReader: metadataReader,
                annotationCoordinator: annotationCoordinator,
                scoresDirectory: scoresDirectory,
                defaultStaffSize: ReaderDeviceDefaults.staffSize(isTablet: true),
                defaultHonorLayoutBreaks: ReaderDeviceDefaults.honorLayoutBreaks(isTablet: true),
                playbackController: playbackController,
                analytics: analytics,
            ),
        )
    }

    /// The mode this screen can actually draw. See `ReaderLayoutMode.macDisplayMode(storedRawValue:)` — the same fold
    /// the View menu's picker resolves its selection with, so the checkmark and the container can never disagree.
    private var layoutMode: ReaderLayoutMode {
        .macDisplayMode(storedRawValue: layoutModeRaw)
    }

    public var body: some View {
        // `frame` + `background` below paint the reading surface as one sheet of paper. `ScoreView` paints itself
        // opaque white, and iOS pins the whole Reader to a light appearance (`hostingAppearance(.light)`) so the
        // margins around it match; that compat helper is a no-op on macOS, so the ground is painted here instead.
        // A later task gives the Mac reader the proper scoped appearance and both lines go with it.
        //
        // On the ROOT, not on the score container: applied there it covered only the `.loaded` branch, so the
        // spinner, the load-failure panel and the PDF placeholder each sat on the window's dark ground in dark
        // mode — a dark-to-white flash on every open, and a dark error sheet inside an otherwise white reader. It
        // also has to hold for Page mode's container, which is a second view; up here it covers every load state
        // and every layout mode at once.
        //
        // The `frame` is what makes that true: the score container fills its column on its own (`GeometryReader`)
        // but the spinner does not, and a background sizes itself to what it is behind — without it the ground
        // would be a white disc the size of a `ProgressView` on an otherwise dark column.
        MacScoreContentView(
            viewModel: viewModel,
            layoutMode: layoutMode,
            collapseMultiMeasureRests: collapseMultiMeasureRests,
            showInvisibleElements: showInvisibleElements,
            showAllMeasureNumbers: showAllMeasureNumbers,
            autoFollowEnabled: autoFollowEnabled,
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .navigationTitle(viewModel.scoreItem.title)
        .task {
            // What the view model is told is the mode this screen actually DRAWS, not the raw preference — that is
            // what the vertical pin protected, and it still has to hold now that the pin is a real branch:
            // `playback_started` must never report a mode that is not on screen. `layoutMode` folds the one mode the
            // Mac cannot draw (horizontal) into the one it substitutes, so the two can no longer disagree.
            viewModel.currentLayoutMode = layoutMode
            viewModel.playbackSession.startObservingCursor()
            viewModel.playbackSession.startObservingSoundfontDownload()
            await viewModel.load()
            await viewModel.playbackSession.prepareForPlayback()
            // Seed the engine from the persisted preference at view start, exactly as the iOS screen does. A no-op
            // while `playbackController` is nil.
            await viewModel.tempoModel.setMetronomeEnabled(isMetronomeEnabled)
        }
        .onAppear { viewModel.analytics.logScreen(.reader) }
        .onDisappear {
            // Unconditional, unlike iOS: that screen guards this teardown on `scenePhase == .active` because
            // backgrounding an iPad mid-PiP fires `onDisappear` without the user having left the Reader. There is
            // no PiP on the Mac, and closing the window (or switching the detail column to another score) is
            // always a real close.
            let viewModel = viewModel
            viewModel.endAnnotationSessionIfNeeded()
            Task {
                await viewModel.flushPendingAnnotationSave()
                await viewModel.playbackSession.releaseEngine()
            }
        }
        .onChange(of: isMetronomeEnabled) { _, newValue in
            Task { await viewModel.tempoModel.setMetronomeEnabled(newValue) }
        }
        // The View menu can change the mode while the reader is open; the analytics mode has to follow it there too,
        // not only at the `task` above.
        .onChange(of: layoutMode) { _, newValue in
            viewModel.currentLayoutMode = newValue
        }
    }
}

/// The live score container plus the load-state switch, extracted from `MacReaderRootScreen.body` so the per-tick
/// playback-cursor reads (`displayCursor` / `scrollAnchorCursor`) stay scoped to THIS view's body.
///
/// The iOS `ScoreContentView` exists for the same reason and its doc comment carries the measurement: read at the
/// root, those cursors re-rendered the whole screen on every tick during playback. Nothing on the Mac drives a cursor
/// yet, but getting the boundary right now costs one struct and getting it wrong later costs a rewrite.
struct MacScoreContentView: View {
    let viewModel: ReaderViewModel
    /// Already normalized to a mode the Mac can draw — see `MacReaderRootScreen.layoutMode`.
    let layoutMode: ReaderLayoutMode
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let showAllMeasureNumbers: Bool
    let autoFollowEnabled: Bool

    var body: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView().controlSize(.large)
        case .loaded:
            if let score = viewModel.visibleScore {
                scoreContainer(score: score)
            } else {
                ProgressView().controlSize(.large)
            }
        case .loadedPDF:
            // PARITY(macos): PDF renditions in the reader — `PagedPDFContainer` / `VerticalPDFContainer` are
            //   `PDFKit` + `UIScrollView` surfaces gated to iOS, so a PDF-backed item has nothing to draw on the Mac
            //   and says so instead. The same gap covers `displaySource == .originalPDF` for an item folino DID read
            //   into notation — the Mac has no way to switch to the original.
            unavailable
        case let .failed(error):
            ContentUnavailableView {
                Label {
                    Text("reader.error.cannotOpen.title", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(describeReaderError(error))
            } actions: {
                Button { Task { await viewModel.load() } } label: {
                    Text("reader.error.retry", bundle: .module)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// The mode branch. Both containers take the cursors as VALUES, read here — one level below the root — so a
    /// per-tick cursor change re-renders the container and the leaves beneath it and never `MacReaderRootScreen`.
    ///
    /// `.horizontal` cannot arrive (the root folds it into `.page`), but the switch spells it out rather than
    /// defaulting: if the Mac ever grows a horizontal container, this is the line that has to change.
    @ViewBuilder
    private func scoreContainer(score: Score) -> some View {
        switch layoutMode {
        case .page, .horizontal:
            MacPagedScoreContainer(
                score: score,
                staffSize: viewModel.layoutModel.effectiveStaffSize,
                honorLayoutBreaks: viewModel.layoutModel.effectiveHonorLayoutBreaks,
                collapseMultiMeasureRests: collapseMultiMeasureRests,
                showInvisibleElements: showInvisibleElements,
                showAllMeasureNumbers: showAllMeasureNumbers,
                playbackCursor: viewModel.playbackSession.displayCursor,
                pageAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,
                autoFollowEnabled: autoFollowEnabled,
                transposeSemitones: viewModel.transposeModel.effectiveSemitones,
                viewModel: viewModel,
            )
        case .vertical:
            MacVerticalScoreContainer(
                score: score,
                staffSize: viewModel.layoutModel.effectiveStaffSize,
                honorLayoutBreaks: viewModel.layoutModel.effectiveHonorLayoutBreaks,
                collapseMultiMeasureRests: collapseMultiMeasureRests,
                showInvisibleElements: showInvisibleElements,
                showAllMeasureNumbers: showAllMeasureNumbers,
                playbackCursor: viewModel.playbackSession.displayCursor,
                scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,
                autoFollowEnabled: autoFollowEnabled,
                transposeSemitones: viewModel.transposeModel.effectiveSemitones,
                viewModel: viewModel,
            )
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label {
                Text("reader.error.cannotOpen.title", bundle: .module)
            } icon: {
                Image(systemName: "doc.richtext")
            }
        }
    }
}
#endif
