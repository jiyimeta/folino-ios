// swiftlint:disable file_length
// ReaderRootScreen composes the score/PDF content, top overlay, transport control, and the note-editing chrome/
// lifecycle seam (`ReaderEditingHost`, spec §9); that breadth keeps it just over the file_length budget.

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
    private let leadingIsSidebarToggle: Bool
    /// Screenshot-only: when non-nil, renders in place of the live score container, so the top chrome and bottom
    /// transport stay LIVE (and follow future app changes) while the score + ink come from a real-device capture the
    /// simulator can't reproduce (PencilKit ink doesn't composite in the simulator; note spacing is OS/device-bound).
    private let scoreContentOverride: AnyView?
    /// The note-editing injection seam (design spec §9, Option 1). `nil` means this Reader instance never enters edit
    /// mode — the edit button in `ReaderTopOverlay` stays hidden and `startEditing()`/`finishEditing()` are no-ops.
    /// The App composition root (Task 15) is the only caller that supplies a non-nil host; the Reader never imports or
    /// references the Editor feature that owns the other end of the seam.
    private let editingHost: ReaderEditingHost?
    /// Builds the Editor feature's chrome (score-info bar, keyboard, 完了 button) from the current selection. Supplied
    /// by the App alongside `editingHost`; `nil` hides the chrome overlay (mirrors `editingHost == nil`).
    private let editingChrome: ((ReaderEditingChromeContext) -> AnyView)?

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

    /// Screenshot-capture mode (launch arg `-readerCaptureMode 1`): hides the top chrome and bottom transport so a real
    /// device produces a clean score+ink image (no toolbar shadow bleeding into it) for the marketing shot, which then
    /// composites that image UNDER the live chrome/transport (see `scoreContentOverride`). No effect in normal use.
    private var isCaptureMode: Bool {
        UserDefaults.standard.bool(forKey: "readerCaptureMode")
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
        annotationCoordinator: AnnotationSaveCoordinator,
        scoresDirectory: URL,
        playbackController: (any PlaybackController)? = nil,
        pdfPlaybackParser: (any PDFPlaybackParser)? = nil,
        museScoreGeneralProvider: (any MuseScoreGeneralProvider)? = nil,
        playlistID: PlaylistID? = nil,
        analytics: any Analytics = NoopAnalytics(),
        openedFrom: AnalyticsSource = .libraryAll,
        onBack: (() -> Void)? = nil,
        hidesBackButton: Bool = false,
        leadingIsSidebarToggle: Bool = false,
        scoreContentOverride: AnyView? = nil,
        editingHost: ReaderEditingHost? = nil,
        editingChrome: ((ReaderEditingChromeContext) -> AnyView)? = nil,
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
                annotationCoordinator: annotationCoordinator,
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
        self.leadingIsSidebarToggle = leadingIsSidebarToggle
        self.scoreContentOverride = scoreContentOverride
        self.editingHost = editingHost
        self.editingChrome = editingChrome
    }

    public var body: some View {
        ZStack {
            Group {
                if let scoreContentOverride {
                    scoreContentOverride // screenshot capture stands in for the live score; chrome + transport live
                } else {
                    content
                }
            }
            .safeAreaPadding(.top, isCaptureMode ? 0 : ReaderTopOverlay.height)
            .safeAreaPadding(.bottom, isCaptureMode ? 0 : bottomControlInset)
            if ReaderPiPSession.isSupported {
                ScorePiPHostView(coordinator: viewModel.pipSession.coordinator)
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
            topAndBottomChrome
            editingChromeOverlay
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
        .onChange(of: editingHost?.isExitRequested ?? false) { _, requested in
            // The editing chrome's 完了 button lives in App-injected code and can't call `finishEditing()` directly
            // (the Reader never exposes it), so it signals exit through the host instead.
            if requested { finishEditing() }
        }
    }

    /// The floating top overlay + bottom transport, both faded out (opacity + `allowsHitTesting`) while editing so the
    /// App-injected chrome reads as the foreground without losing the reader's mounted playback / sheet state.
    /// Extracted from `body` to keep the outer `ZStack` closure under SwiftLint's body-length limit.
    private var topAndBottomChrome: some View {
        VStack(spacing: 0) {
            if !isCaptureMode {
                ReaderTopOverlay(
                    viewModel: viewModel,
                    onBack: hidesBackButton ? nil : (onBack ?? { dismiss() }),
                    leadingIsSidebarToggle: leadingIsSidebarToggle,
                    onShowPDFNotice: { isPDFNoticePresented = true },
                    onStartEditing: editingHost == nil ? nil : { startEditing() },
                )
                // Fade the top overlay out while editing — its buttons (back / share / annotate / inspectors) have no
                // meaning over the editing surface, and the App-injected chrome takes over that space instead. Same
                // opacity-only + `allowsHitTesting(false)` treatment as the transport's `isAnnotating` fade below, so
                // the mounted state (popovers, sheets) survives an edit session.
                .opacity(editingHost?.isEditing == true ? 0 : 1)
                    .allowsHitTesting(editingHost?.isEditing != true)
                    .animation(.easeOut(duration: 0.2), value: editingHost?.isEditing)
            }
            Spacer()
            // Fade the transport control out while annotating (or editing) so it doesn't sit over the drawing /
            // editing surface. It stays mounted (opacity only) and stops taking touches, so a partial seek / playback
            // state survives the session. Layout is deliberately left untouched: `bottomControlInset` /
            // `bottomControlContentHeight` don't depend on `isAnnotating` / editing, so page breaks (and the vertical
            // bottom clearance) stay identical whether the card is shown or hidden — it just fades in place.
            if !isCaptureMode {
                ReaderTransportControl(viewModel: viewModel, showSeekBar: showSeekBar)
                    .opacity(viewModel.isAnnotating || editingHost?.isEditing == true ? 0 : 1)
                    .allowsHitTesting(!viewModel.isAnnotating && editingHost?.isEditing != true)
                    .animation(.easeOut(duration: 0.2), value: viewModel.isAnnotating)
                    .animation(.easeOut(duration: 0.2), value: editingHost?.isEditing)
            }
        }
    }

    /// The App-injected editing chrome (score-info bar, keyboard, 完了), shown only while `editingHost.isEditing` and
    /// a builder was supplied. `nil` on either side leaves this an empty overlay — the default, so every existing
    /// `ReaderRootScreen` call site (which passes neither) is unaffected.
    @ViewBuilder
    private var editingChromeOverlay: some View {
        if let host = editingHost, host.isEditing, let editingChrome {
            editingChrome(ReaderEditingChromeContext(selectionScreenFrame: host.selectionScreenFrame))
                .transition(.opacity)
        }
    }

    /// Enter edit mode: pause playback (the editing surface never plays), end any in-progress annotation session (ink
    /// and note editing are mutually exclusive surfaces), then hand the currently loaded score to the host so the App
    /// can seed the Editor feature's view model.
    private func startEditing() {
        guard case let .loaded(score) = viewModel.loadState, let host = editingHost else { return }
        Task {
            if viewModel.playbackSession.isPlaying { await viewModel.playbackSession.togglePlayback() }
            viewModel.endAnnotationSessionIfNeeded()
            host.editedScore = score
            host.editGeneration += 1
            host.isEditing = true
            host.onBeginEditing(score)
        }
    }

    /// Exit edit mode: let the App flush any final edit, adopt the edited score back into the Reader (reloading the
    /// audio engine so playback reflects the new notes — see `ReaderViewModel.adoptEditedScore`), then reset the
    /// host's transient state for the next editing session.
    private func finishEditing() {
        guard let host = editingHost else { return }
        Task {
            host.onEndEditing()
            if let edited = host.editedScore { await viewModel.adoptEditedScore(edited) }
            host.isEditing = false
            host.selection = .none
            host.caretItem = nil
            host.resetExitRequest()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let host = editingHost, host.isEditing, let editScore = host.editedScore {
            // Forced-vertical editing presentation (spec §11): raw score (no transpose / hidden staves / collapsed
            // multi-measure rests) so positional IDs the Editor VM tracks stay valid, and no playback cursor / auto-
            // follow since the transport is hidden for the duration.
            VerticalScoreContainer(
                score: editScore,
                staffSize: viewModel.layoutModel.staffSize,
                honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                collapseMultiMeasureRests: false,
                showInvisibleElements: showInvisibleElements,
                playbackCursor: nil,
                scrollAnchorCursor: nil,
                autoFollowEnabled: false,
                transposeSemitones: 0,
                bottomControlClearance: bottomControlContentHeight,
                viewModel: viewModel,
                editingHost: host,
            )
        } else {
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
