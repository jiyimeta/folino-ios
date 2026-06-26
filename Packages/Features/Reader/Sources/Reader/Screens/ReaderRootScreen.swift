import Domain
import SheetMusicCore
import SwiftUI
import UIKit
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

    @Environment(\.scenePhase) private var scenePhase

    private var layoutMode: ReaderLayoutMode {
        ReaderLayoutMode(rawValue: layoutModeRaw) ?? .page
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
        museScoreGeneralProvider: (any MuseScoreGeneralProvider)? = nil,
        playlistID: PlaylistID? = nil,
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
                museScoreGeneralProvider: museScoreGeneralProvider,
                playlistID: playlistID,
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
                )
                Spacer()
                ReaderTransportControl(viewModel: viewModel, showSeekBar: showSeekBar)
            }
        }
        .navigationTitle("")
        .toolbarVisibility(.hidden, for: .navigationBar)
        .task {
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
            guard scenePhase == .active else { return }
            let viewModel = viewModel
            Task {
                await viewModel.flushPendingAnnotationSave()
                await viewModel.playbackSession.releaseEngine()
            }
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
                        transposeSemitones: viewModel.transposeModel.semitones,
                        viewModel: viewModel,
                    )
                }
            } else {
                ProgressView().controlSize(.large)
            }
        case .loadedPDF:
            // PDF container dispatch is wired in a later task; until then the loaded PDF state shows a placeholder so
            // the `LoadState` switch stays exhaustive.
            ProgressView().controlSize(.large)
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
