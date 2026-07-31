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

    /// Opt-out: on unless the user turns it off (see `ReaderGlobalSettingsKey.pictureInPictureEnabled`).
    @AppStorage(ReaderGlobalSettingsKey.pictureInPictureEnabled)
    private var isPiPEnabled = true

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
        showsSeekBarNow
            ? ReaderTransportControl.expandedContentHeight
            : ReaderTransportControl.collapsedContentHeight
    }

    /// Whether the seek card is showing right now. The user's `showSeekBar` preference is overridden to `false` while
    /// editing: the pad already owns most of the bottom of the screen, and the expanded card would push it up over
    /// the music. Note this shrinks the bottom reserve (114 → 44) on entering edit mode, so a PAGE-mode score with
    /// the seek bar enabled re-paginates for the edit session — the trade the compact transport buys.
    private var showsSeekBarNow: Bool {
        showSeekBar && editingHost?.isEditing != true
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
            scoreLayer
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
            // Press play while editing and playback starts at the selected note. Wired here because this is where the
            // editing host and the playback session are both in scope; outside edit mode the closure returns nil and
            // the transport behaves exactly as it did.
            editingHost?.onSelectionMade = { [weak viewModel] in
                viewModel?.playbackSession.hideDisplayedCursor()
            }
            viewModel.playbackSession.startCursorProvider = { [weak editingHost] in
                guard let host = editingHost, host.isEditing,
                      case let .single(item) = host.selection
                else { return nil }
                return .item(item)
            }
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
        // Mirror playback state into the seam so the App can put the editing pad to sleep while the cursor runs. This
        // reads `isPlaying`, not the cursor, so it re-renders on play/pause only — never per tick.
        .onChange(of: viewModel.playbackSession.isPlaying, initial: true) { _, isPlaying in
            editingHost?.isPlaying = isPlaying
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
            // Fade the transport control out while annotating so it doesn't sit over the drawing surface. It stays
            // mounted (opacity only) and stops taking touches, so a partial seek / playback state survives the
            // session. Layout is deliberately left untouched: `bottomControlInset` / `bottomControlContentHeight`
            // don't depend on `isAnnotating`, so page breaks (and the vertical bottom clearance) stay identical
            // whether the card is shown or hidden — it just fades in place.
            //
            // Editing does NOT hide it: you can play the passage you're editing to hear what you just wrote. It stays
            // anchored to the bottom edge — only the pad moves — and drops to its compact pill for the duration (see
            // `showsSeekBarNow`), because the editing pad already claims most of the bottom of the screen.
            if !isCaptureMode {
                ReaderTransportControl(viewModel: viewModel, showSeekBar: showsSeekBarNow)
                    .opacity(viewModel.isAnnotating ? 0 : 1)
                    .allowsHitTesting(!viewModel.isAnnotating)
                    .animation(.easeOut(duration: 0.2), value: viewModel.isAnnotating)
            }
        }
    }

    /// The App-injected editing chrome (score-info bar, keyboard, 完了), shown only while `editingHost.isEditing` and
    /// a builder was supplied. `nil` on either side leaves this an empty overlay — the default, so every existing
    /// `ReaderRootScreen` call site (which passes neither) is unaffected.
    @ViewBuilder
    private var editingChromeOverlay: some View {
        if let host = editingHost, host.isEditing, let editingChrome {
            editingChrome(ReaderEditingChromeContext(
                bottomTransportClearance: bottomControlContentHeight,
            ))
            .transition(.opacity)
        }
    }

    /// Enter edit mode: pause playback (the editing surface never plays), end any in-progress annotation session (ink
    /// and note editing are mutually exclusive surfaces), then hand the currently loaded score to the host so the App
    /// can seed the Editor feature's view model.
    private func startEditing() {
        guard case let .loaded(score) = viewModel.loadState, let host = editingHost else { return }
        Task {
            // Playback is NOT stopped: editing and listening coexist. Annotation still is — ink and note editing are
            // mutually exclusive surfaces.
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

    /// The score being edited, or `nil` when not editing.
    ///
    /// Raw apart from ONE display transform: clef overrides survive, because `applying(clefOverrides:)` only
    /// REPLACES a staff's opening clef element (or sets `defaultClefType`) — it never inserts or removes elements, so
    /// every index the editor holds still points at the same note. Dropping it made a staff the user had re-clefed
    /// jump back to its authored clef the moment they started editing it. Transpose, hidden staves and
    /// multi-measure-rest collapse stay off, since those DO renumber elements.
    ///
    /// Computed here rather than in `ScoreContentView` so it's rebuilt per edit, not per playback tick.
    private var editingScore: Score? {
        guard let host = editingHost, host.isEditing, let editScore = host.editedScore else { return nil }
        return editScore.applying(clefOverrides: viewModel.layoutModel.staffClefOverrides)
    }

    /// Which edit `editingScore` is — the containers' relayout key, read HERE so the two always travel together.
    ///
    /// The containers used to read `editingHost.editGeneration` themselves. That looked equivalent and wasn't: the
    /// bump invalidated the container directly through observation, so its body re-ran — and started the relayout —
    /// while `score` was still the previous edit's, because this screen hadn't re-rendered to hand down the new one
    /// yet. The layout key's `scoreSignature` is deliberately note-blind (parts / staves / division / opening clef),
    /// so when the new score DID arrive the key was unchanged and no second relayout ran. The result was a bar that
    /// kept its pre-edit engraving until some later edit happened to line up — measured as "the note only appears
    /// when you type the next one", with the relayout finishing on time every time and quietly re-engraving the
    /// score as it was BEFORE the note was written.
    private var editingScoreVersion: Int {
        guard let host = editingHost, host.isEditing else { return 0 }
        return host.editGeneration
    }

    /// The score / PDF layer (or the screenshot override), inset for the top overlay + bottom transport. Extracted
    /// from `body` to keep the `ZStack` closure within SwiftLint's body-length budget; constructing
    /// `ScoreContentView` reads no per-tick playback state, so this stays off the auto-follow re-render path.
    private var scoreLayer: some View {
        Group {
            if let scoreContentOverride {
                scoreContentOverride // screenshot capture stands in for the live score; chrome + transport live
            } else {
                // Extracted into its own view so the per-tick auto-follow cursor reads don't re-render this root body
                // (which would rebuild the top overlay and regenerate its inspector popover every tick — see
                // `ScoreContentView`). Editing goes through the SAME view, so entering and leaving edit mode doesn't
                // remount the container and blank the score while it re-lays out.
                ScoreContentView(
                    viewModel: viewModel,
                    layoutMode: layoutMode,
                    pdfLayoutMode: pdfLayoutMode,
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                    showInvisibleElements: showInvisibleElements,
                    autoFollowEnabled: autoFollowEnabled,
                    pageTurnButtonsVisible: pageTurnButtonsVisible,
                    bottomControlContentHeight: bottomControlContentHeight,
                    editingScore: editingScore,
                    editingScoreVersion: editingScoreVersion,
                    editingHost: editingHost,
                )
            }
        }
        .safeAreaPadding(.top, isCaptureMode ? 0 : ReaderTopOverlay.height + horizontalEditingInsets.top)
        .safeAreaPadding(.bottom, isCaptureMode ? 0 : bottomControlInset + horizontalEditingInsets.bottom)
    }

    /// Extra room for the editing cluster, applied to HORIZONTAL mode only.
    ///
    /// Horizontal lays out at its natural content width, so insetting the viewport just shows less of the score — no
    /// re-engraving. Page mode is deliberately excluded: its bottom inset feeds `pageHeight` into `LayoutPaginator`,
    /// so reserving room for the pad there would re-paginate the score the moment editing began, and the page breaks
    /// would differ between reading and editing the same file. Vertical handles its own insets as scroll-content
    /// padding inside `VerticalScoreContainer`.
    private var horizontalEditingInsets: (top: CGFloat, bottom: CGFloat) {
        guard layoutMode == .horizontal, let host = editingHost, host.isEditing else { return (0, 0) }
        return (host.editingChromeTopInset, host.editingChromeBottomInset)
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
