import Domain
import SheetMusicCore
import SwiftUI
import UIKit
import UtilityCore
import UtilityUI

@MainActor
public struct ReaderRootScreen: View {
    @State private var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    private let onBack: (() -> Void)?
    private let hidesBackButton: Bool

    @AppStorage(ReaderGlobalSettingsKey.layoutMode)
    private var layoutModeRaw: String = ReaderLayoutMode.page.rawValue

    @AppStorage(ReaderGlobalSettingsKey.metronomeEnabled)
    private var isMetronomeEnabled = false

    @AppStorage(ReaderGlobalSettingsKey.pictureInPictureEnabled)
    private var isPiPEnabled = false

    @AppStorage(ReaderGlobalSettingsKey.collapseMultiMeasureRests)
    private var collapseMultiMeasureRests = false

    @AppStorage(ReaderGlobalSettingsKey.showInvisibleElements)
    private var showInvisibleElements = false

    @AppStorage(ReaderGlobalSettingsKey.keepScreenAwakeEnabled)
    private var keepScreenAwake = true

    @AppStorage(ReaderGlobalSettingsKey.showSeekBarEnabled)
    private var showSeekBar = true

    @AppStorage(ReaderGlobalSettingsKey.autoFollowEnabled)
    private var autoFollowEnabled = true

    @AppStorage(ReaderGlobalSettingsKey.pageTurnButtonsVisible)
    private var pageTurnButtonsVisible = true

    /// `true` once the user chose "Don't show again" on the PDF-playback caveat — stops it from auto-presenting.
    @AppStorage(ReaderGlobalSettingsKey.pdfPlaybackNoticeDismissed)
    private var pdfPlaybackNoticeDismissed = false

    /// Drives the PDF-playback caveat dialog: shown automatically the first time an opened PDF becomes playable
    /// (unless permanently dismissed), and on demand from the PDF badge. `hasAutoShownPDFNotice` keeps the
    /// auto-presentation to once per Reader open; "OK" just closes it for now, "Don't show again" sets the flag above.
    @State private var isPDFNoticePresented = false
    @State private var hasAutoShownPDFNotice = false

    @Environment(\.scenePhase) private var scenePhase

    private var layoutMode: ReaderLayoutMode {
        ReaderLayoutMode(rawValue: layoutModeRaw) ?? .page
    }

    /// The layout mode to use for PDFs: the persisted mode if it is PDF-allowed, else page. Guards against a stale
    /// horizontal selection carried over from a score.
    private var pdfLayoutMode: ReaderLayoutMode {
        viewModel.capabilities.availableLayoutModes.contains(layoutMode) ? layoutMode : .page
    }

    /// Space the bottom control reserves above the score, applied only in horizontal / page modes —
    /// vertical mode lets the score scroll under the floating control. The control overlays the
    /// score's bottom edge whether or not the seek bar is shown, so both states inset; the expanded
    /// card is taller than the compact pill.
    private var bottomControlInset: CGFloat {
        switch layoutMode {
        case .vertical:
            0
        case .horizontal, .page:
            bottomControlContentHeight
        }
    }

    /// Height the bottom transport control reserves above the bottom safe area — the expanded seek card or the compact
    /// pill, depending on `showSeekBar`. Vertical mode passes this into the score container so the scroll content can
    /// pad its bottom by the control's full screen-edge clearance (this height plus the safe area), letting the last
    /// system clear the control once scrolled all the way down.
    private var bottomControlContentHeight: CGFloat {
        showSeekBar
            ? ReaderTransportControl.expandedContentHeight
            : ReaderTransportControl.collapsedContentHeight
    }

    public init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService,
        metadataReader: any ScoreMetadataReading,
        annotationStore: any AnnotationStore,
        scoresDirectory: URL,
        playbackController: (any PlaybackController)? = nil,
        pdfPlaybackParser: (any PDFPlaybackParser)? = nil,
        museScoreGeneralProvider: (any MuseScoreGeneralProvider)? = nil,
        playlistID: PlaylistID? = nil,
        analytics: any Analytics = NoopAnalytics(),
        openedFrom: AnalyticsSource = .libraryAll,
        onBack: (() -> Void)? = nil,
        hidesBackButton: Bool = false,
    ) {
        // Seed the device-class default at construction time. The view model only uses this if no persisted record
        // exists.
        let initialDefault: Double = 14 // TBD: device-class override (follow-up)
        _viewModel = State(
            wrappedValue: ReaderViewModel(
                scoreItem: scoreItem,
                repository: repository,
                gateway: gateway,
                shareService: shareService,
                metadataReader: metadataReader,
                annotationStore: annotationStore,
                scoresDirectory: scoresDirectory,
                defaultStaffSize: initialDefault,
                playbackController: playbackController,
                pdfPlaybackParser: pdfPlaybackParser,
                museScoreGeneralProvider: museScoreGeneralProvider,
                playlistID: playlistID,
                analytics: analytics,
                openedFrom: openedFrom,
            ),
        )
        self.onBack = onBack
        self.hidesBackButton = hidesBackButton
    }

    public var body: some View {
        ZStack {
            content
                .safeAreaPadding(.top, ReaderTopOverlay.height)
                .safeAreaPadding(.bottom, bottomControlInset)
            if ReaderPiPSession.isSupported {
                ScorePiPHostView(coordinator: viewModel.pipSession.coordinator)
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                ReaderTopOverlay(
                    viewModel: viewModel,
                    onBack: hidesBackButton ? nil : (onBack ?? { dismiss() }),
                    onShowPDFNotice: { isPDFNoticePresented = true },
                )
                Spacer()
                // Fade the transport control out while annotating so it doesn't sit over the drawing surface. It stays
                // mounted (opacity only) and stops taking touches, so a partial seek/playback state survives the
                // annotation session. Layout is deliberately left untouched: `bottomControlInset` /
                // `bottomControlContentHeight` don't depend on `isAnnotating`, so page breaks (and the vertical bottom
                // clearance) stay identical whether the card is shown or hidden — the card just fades in place.
                ReaderTransportControl(viewModel: viewModel, showSeekBar: showSeekBar)
                    .opacity(viewModel.isAnnotating ? 0 : 1)
                    .allowsHitTesting(!viewModel.isAnnotating)
                    .animation(.easeOut(duration: 0.2), value: viewModel.isAnnotating)
            }
        }
        .navigationTitle("")
        .toolbarVisibility(.hidden, for: .navigationBar)
        .pdfPlaybackNoticeAlert(
            state: viewModel.pdfPlayback,
            isPresented: $isPDFNoticePresented,
            onDontShowAgain: { pdfPlaybackNoticeDismissed = true },
        )
        .onChange(of: viewModel.isPDFPlaybackReady) { _, isReady in
            // Auto-present the caveat once per open, the first time a PDF becomes playable — unless dismissed for good.
            guard isReady, !hasAutoShownPDFNotice, !pdfPlaybackNoticeDismissed else { return }
            hasAutoShownPDFNotice = true
            isPDFNoticePresented = true
        }
        .task {
            // Mirror the global layout mode onto the view model so `playback_started` carries the right layout. Kept in
            // sync by `.onChange(of: layoutMode)` below.
            viewModel.currentLayoutMode = layoutMode
            viewModel.playbackSession.startObservingCursor()
            viewModel.playbackSession.startObservingSoundfontDownload()
            viewModel.pipSession.setEnabled(isPiPEnabled)
            viewModel.pipSession.setCollapseMultiMeasureRests(collapseMultiMeasureRests)
            viewModel.pipSession.setShowInvisibleElements(showInvisibleElements)
            await viewModel.load()
            await viewModel.playbackSession.prepareForPlayback()
            // Initial sync: the engine starts up unaware of persisted state, so seed it from the @AppStorage value at
            // view start.
            await viewModel.tempoModel.setMetronomeEnabled(isMetronomeEnabled)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepScreenAwake }
        .onAppear { viewModel.analytics.logScreen(.reader) }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            // `onDisappear` fires both on a genuine in-app close (back to the Library) AND when the app merely
            // backgrounds — on iPad, sending the app Home while PiP is auto-starting tears the Reader's view off the
            // screen and fires `onDisappear` even though the user hasn't left the Reader. Releasing the engine there
            // stops playback and demotes/deactivates the audio session, which suspends the app and kills the freshly
            // started PiP window. Only tear down on a real close: by the time `onDisappear` runs during backgrounding
            // the scene is already `.inactive`/`.background`, so `.active` uniquely identifies an in-app dismissal.
            //
            // `engine.prepare(score:)` ends with `AVAudioEngine.start()` + `engine.pause()`. iOS treats a running
            // engine on a `.playback` session as active audio output and would inhibit auto-lock for the rest of the
            // app's lifetime if we never tore it down — releasing on a real close lets screen lock resume once the
            // user leaves the Reader; backgrounding keeps the engine alive so background audio + PiP continue.
            let viewModel = viewModel
            viewModel.endAnnotationSessionIfNeeded()
            guard scenePhase == .active else { return }
            Task {
                await viewModel.flushPendingAnnotationSave()
                await viewModel.playbackSession.releaseEngine()
            }
        }
        .onChange(of: layoutMode) { _, newValue in
            // The layout picker lives in the visual inspector and writes the shared `@AppStorage` key, so logging the
            // change here (the one place that owns the view model) captures every layout switch, score or PDF.
            viewModel.currentLayoutMode = newValue
            viewModel.analytics.log(.layoutModeChanged(newValue))
        }
        .onChange(of: keepScreenAwake) { _, newValue in
            UIApplication.shared.isIdleTimerDisabled = newValue
        }
        .onChange(of: isMetronomeEnabled) { _, newValue in
            // The iPad fix: if the user toggles metronome from the Settings sheet while a Reader detail pane is alive
            // in the same scene, the running engine has to be reconfigured here — the Inspector's button no longer
            // drives that side effect.
            Task { await viewModel.tempoModel.setMetronomeEnabled(newValue) }
        }
        .onChange(of: isPiPEnabled) { _, newValue in
            viewModel.pipSession.setEnabled(newValue)
        }
        .onChange(of: collapseMultiMeasureRests) { _, newValue in
            viewModel.pipSession.setCollapseMultiMeasureRests(newValue)
        }
        .onChange(of: showInvisibleElements) { _, newValue in
            viewModel.pipSession.setShowInvisibleElements(newValue)
        }
        .onChange(of: scenePhase) { _, newValue in
            // The Settings spec dismisses PiP whenever the app returns to the foreground, regardless of how it was
            // started.
            if newValue == .active {
                viewModel.pipSession.dismissIfActive()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView().controlSize(.large)
        case .loaded:
            // `visibleScore` is the clef-applied / transposed / hidden-filtered score, cached on the view model and
            // recomputed only when its inputs change — so this body no longer rebuilds the score on every re-eval.
            if let visible = viewModel.visibleScore {
                switch layoutMode {
                case .vertical:
                    VerticalScoreContainer(
                        score: visible,
                        staffSize: viewModel.layoutModel.staffSize,
                        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                        collapseMultiMeasureRests: collapseMultiMeasureRests,
                        showInvisibleElements: showInvisibleElements,
                        playbackCursor: viewModel.playbackSession.displayCursor,
                        scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,
                        autoFollowEnabled: autoFollowEnabled,
                        transposeSemitones: viewModel.transposeModel.semitones,
                        bottomControlClearance: bottomControlContentHeight,
                        viewModel: viewModel,
                    )
                case .horizontal:
                    HorizontalScoreContainer(
                        score: visible,
                        staffSize: viewModel.layoutModel.staffSize,
                        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                        collapseMultiMeasureRests: collapseMultiMeasureRests,
                        showInvisibleElements: showInvisibleElements,
                        playbackCursor: viewModel.playbackSession.displayCursor,
                        scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,
                        autoFollowEnabled: autoFollowEnabled,
                        transposeSemitones: viewModel.transposeModel.semitones,
                        viewModel: viewModel,
                    )
                case .page:
                    PagedScoreContainer(
                        score: visible,
                        staffSize: viewModel.layoutModel.staffSize,
                        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                        collapseMultiMeasureRests: collapseMultiMeasureRests,
                        showInvisibleElements: showInvisibleElements,
                        playbackCursor: viewModel.playbackSession.displayCursor,
                        pageAnchorCursor: viewModel.playbackSession.pageAnchorCursor,
                        autoFollowEnabled: autoFollowEnabled,
                        showsPageTurnButtons: pageTurnButtonsVisible,
                        transposeSemitones: viewModel.transposeModel.semitones,
                        viewModel: viewModel,
                    )
                }
            } else {
                ProgressView().controlSize(.large)
            }
        case let .loadedPDF(document):
            switch pdfLayoutMode {
            case .vertical:
                VerticalPDFContainer(document: document, viewModel: viewModel)
            case .page, .horizontal:
                PagedPDFContainer(
                    document: document,
                    showsPageTurnButtons: pageTurnButtonsVisible,
                    viewModel: viewModel,
                )
            }
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
}

#if DEBUG
/// Documents the shape of a real Score fixture. Not used by the previews below — building a `ReaderRootScreen` preview
/// requires wiring a fake gateway that returns a real `Score`, which is too brittle for a preview. See
/// `PlaybackInspectorScreen` for a productive Score-shaped preview.
@MainActor
private func previewScore() -> Score {
    Score(
        division: 480,
        parts: [],
        metaTags: ["workTitle": "Sample"],
    )
}

#Preview("Loading") {
    ProgressView().controlSize(.large)
}

#Preview("Loaded · vertical · iPhone") {
    // A real assembled-ReaderRootScreen preview would need a fake gateway returning a non-empty Score plus persistence
    // wiring. Snapshot the chrome-only intent here; productive Score shape lives in `PlaybackInspectorScreen`'s
    // preview.
    Text("Run via xcode preview to see the assembled view")
}
#endif
