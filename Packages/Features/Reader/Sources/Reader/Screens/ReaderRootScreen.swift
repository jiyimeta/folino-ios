// swiftlint:disable file_length
// swiftlint:disable type_body_length
// ReaderRootScreen composes the score/PDF content, the self-drawn top strip, transport control, and the note-editing
// chrome/lifecycle seam (`ReaderEditingHost`, spec §9); that breadth keeps it just over the file_length and
// type_body_length budgets.

import Domain
import ReaderInteractionCore
import ScoreUI
import SheetMusicCore
import SwiftUI
import UIKit
import UtilityCore
import UtilityUI

@MainActor
public struct ReaderRootScreen: View {
    @State private var viewModel: ReaderViewModel
    /// Screenshot-only: when non-nil, renders in place of the live score container, so the top chrome and bottom
    /// transport stay LIVE (and follow future app changes) while the score + ink come from a real-device capture the
    /// simulator can't reproduce (PencilKit ink doesn't composite in the simulator; note spacing is OS/device-bound).
    private let scoreContentOverride: AnyView?
    /// The note-editing injection seam (design spec §9, Option 1). `nil` means this Reader instance never enters edit
    /// mode — the edit button in `ReaderTopBarControls` stays hidden and `startEditing()`/`finishEditing()` are
    /// no-ops.
    /// The App composition root is the only caller that supplies a non-nil host; the Reader never imports or
    /// references the Editor feature that owns the other end of the seam.
    private let editingHost: ReaderEditingHost?
    /// Builds the Editor feature's chrome (score-info bar, keyboard, 完了 button) from the current selection. Supplied
    /// by the App alongside `editingHost`; `nil` hides the chrome overlay (mirrors `editingHost == nil`).
    private let editingChrome: ((ReaderEditingChromeContext) -> AnyView)?
    /// The editing row the App injects into the top strip's control tier while a session runs. `nil` in a Reader
    /// with no editing seam.
    private let editingTopBar: ((ReaderEditingChromeContext) -> AnyView)?
    /// The editing session's cutout-tier content (完了 leading, revert trailing), drawn by this screen's own
    /// `ReaderCutoutTier` rather than by whatever `editingTopBar` returns — see the `.overlay` below and review
    /// Important 4. `nil` alongside `editingTopBar` in a Reader with no editing seam.
    private let editingCutoutTier: ((ReaderEditingChromeContext) -> ReaderEditingCutoutTierContent)?
    /// One-shot: enters edit mode as soon as the score finishes loading (see the `.task` in `body`), for a score that
    /// was just created and should open straight into an editing session rather than at the score view. Mirrors
    /// `startScreenshotEditingIfRequested`'s call site; init-immutable, so it fires exactly once per screen instance.
    private let startInEditMode: Bool
    /// Pops back to the library. Supplied only by the compact stack; `nil` elsewhere, which hides the chevron.
    private let onBack: (@MainActor () -> Void)?
    /// Reveals or collapses the library sidebar. Supplied only in the regular split view; `nil` elsewhere.
    private let onToggleSidebar: (@MainActor () -> Void)?
    /// Asks the App to hide or show the status bar. A closure rather than `statusBarHidden(_:)` applied here, because
    /// applied here it does nothing: measured on an iPhone 16 Pro, the Reader requesting the hide reported
    /// `hideStatusBar=true` while the window scene's own `statusBarManager.isStatusBarHidden` stayed `false` and the
    /// clock stayed on screen. The same modifier on `AppShellView`'s root hides it — including over a pushed Reader —
    /// so the preference is not surviving the trip out of a `navigationDestination`. The status bar belongs to the
    /// window either way, and the window is the App's; this screen only decides.
    ///
    /// The App is told `false` again on disappear: a Reader popped mid-edit would otherwise leave the whole app
    /// without a clock.
    private let onStatusBarHiddenChange: (@MainActor (Bool) -> Void)?

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

    @AppStorage(ReaderGlobalSettingsKey.showAllMeasureNumbers)
    private var showAllMeasureNumbers = false

    @AppStorage(ReaderGlobalSettingsKey.keepScreenAwakeEnabled)
    private var keepScreenAwake = true

    @AppStorage(ReaderGlobalSettingsKey.showSeekBarEnabled)
    private var showSeekBar = true

    @AppStorage(ReaderGlobalSettingsKey.autoFollowEnabled)
    private var autoFollowEnabled = true

    @AppStorage(ReaderGlobalSettingsKey.pageTurnButtonsVisible)
    private var pageTurnButtonsVisible = true

    /// `true` once the user chose "Don't show again" on the PDF-source notice — stops it from auto-presenting.
    @AppStorage(ReaderGlobalSettingsKey.pdfSourceNoticeDismissed)
    private var pdfSourceNoticeDismissed = false

    /// Drives the PDF-source notice: shown automatically the first time a PDF-origin item is opened (unless
    /// permanently dismissed), and on demand from the PDF badge. `hasAutoShownPDFNotice` keeps the auto-presentation
    /// to once per Reader open; "OK" just closes it for now, "Don't show again" sets the flag above.
    @State private var isPDFNoticePresented = false
    @State private var hasAutoShownPDFNotice = false

    /// Gate for the destructive re-read. Only raised when `reReadNeedsConfirmation` — a re-read with nothing to lose
    /// runs straight from the menu item.
    @State private var isReReadConfirmPresented = false

    /// The deferred `showSeekBar` write from a transport swipe (see `setSeekBarVisible` for why it is deferred at
    /// all). Kept so a swipe back within the deferral window replaces the pending write instead of racing it.
    @State private var seekBarCommitTask: Task<Void, Never>?

    /// The one-hint-at-a-time coach-mark slot (see `ReaderHintCoordinator`). A singleton, so the "one hint per launch"
    /// budget is spent once no matter how many scores are opened in that launch.
    private let hints = ReaderHintCoordinator.shared

    /// The system's own top safe-area inset (status bar / display cutout), read once so the cutout tier knows
    /// whether a control fits in the reserved band — see `ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset:)`.
    /// Measured via a `Color.clear` proxy attached BEFORE `.safeAreaInset(edge: .top)` in the modifier chain, so it
    /// reports the system's own inset rather than one already inflated by the strip we add.
    @State private var topSafeAreaInset: CGFloat = 0

    @Environment(\.scenePhase) private var scenePhase

    /// Decides where the inspectors are presented from: their own strip button (regular) or this screen (compact).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var layoutMode: ReaderLayoutMode {
        ReaderLayoutMode(rawValue: layoutModeRaw) ?? .page
    }

    /// The clock and the battery sit in exactly the two spots the cutout tier wants, so they're cleared only while
    /// that tier is actually in use — editing, on a device that has one. On a device with no tier there is nothing to
    /// clear and no reason to take the clock away. Hiding the status bar changes no height: the top inset belongs to
    /// the cutout and the system keeps reserving it either way (`ReaderTopBarLayout`'s own doc comment).
    private var statusBarShouldHide: Bool {
        isEditing && ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: topSafeAreaInset)
    }

    /// Screenshot-capture mode (launch arg `-readerCaptureMode 1`): hides the top chrome and bottom transport so a real
    /// device produces a clean score+ink image (no strip shadow bleeding into it) for the marketing shot, which then
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
    /// the music. Note this shrinks the bottom reserve (110 → 44) on entering edit mode, so a PAGE-mode score with
    /// the seek bar enabled re-paginates for the edit session — the trade the compact transport buys.
    private var showsSeekBarNow: Bool {
        showSeekBar && editingHost?.isEditing != true
    }

    /// Every display global the PiP window renders from, as one value — see `PiPDisplayOptions`.
    private var pipDisplayOptions: PiPDisplayOptions {
        .init(
            isEnabled: isPiPEnabled, collapseMultiMeasureRests: collapseMultiMeasureRests,
            showInvisibleElements: showInvisibleElements, showAllMeasureNumbers: showAllMeasureNumbers,
        )
    }

    public init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        originalStore: any ScoreOriginalStore,
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService,
        vocalTunerHandoff: any VocalTunerHandoff,
        metadataReader: any ScoreMetadataReading,
        annotationCoordinator: AnnotationSaveCoordinator,
        scoresDirectory: URL,
        playbackController: (any PlaybackController)? = nil,
        pdfPlaybackParser: (any PDFPlaybackParser)? = nil,
        pdfConversion: PDFScoreConversion? = nil,
        museScoreGeneralProvider: (any MuseScoreGeneralProvider)? = nil,
        playlistID: PlaylistID? = nil,
        analytics: any Analytics = NoopAnalytics(),
        openedFrom: AnalyticsSource = .libraryAll,
        onBack: (@MainActor () -> Void)? = nil,
        onToggleSidebar: (@MainActor () -> Void)? = nil,
        onStatusBarHiddenChange: (@MainActor (Bool) -> Void)? = nil,
        scoreContentOverride: AnyView? = nil,
        editingHost: ReaderEditingHost? = nil,
        editingChrome: ((ReaderEditingChromeContext) -> AnyView)? = nil,
        editingTopBar: ((ReaderEditingChromeContext) -> AnyView)? = nil,
        editingCutoutTier: ((ReaderEditingChromeContext) -> ReaderEditingCutoutTierContent)? = nil,
        startInEditMode: Bool = false,
    ) {
        // Seed the device-class defaults at construction time. The view model only uses these if no persisted record
        // exists — a stored value, including one equal to the default, always wins.
        let deviceStaffSize = ReaderDeviceDefaults.staffSize
        let deviceHonorLayoutBreaks = ReaderDeviceDefaults.honorLayoutBreaks
        _viewModel = State(
            wrappedValue: ReaderViewModel(
                scoreItem: scoreItem,
                repository: repository,
                originalStore: originalStore,
                gateway: gateway,
                shareService: shareService,
                vocalTunerHandoff: vocalTunerHandoff,
                metadataReader: metadataReader,
                annotationCoordinator: annotationCoordinator,
                scoresDirectory: scoresDirectory,
                defaultStaffSize: deviceStaffSize,
                defaultHonorLayoutBreaks: deviceHonorLayoutBreaks,
                playbackController: playbackController,
                pdfPlaybackParser: pdfPlaybackParser,
                pdfConversion: pdfConversion,
                museScoreGeneralProvider: museScoreGeneralProvider,
                playlistID: playlistID,
                analytics: analytics,
                openedFrom: openedFrom,
            ),
        )
        self.scoreContentOverride = scoreContentOverride
        self.editingHost = editingHost
        self.editingChrome = editingChrome
        self.editingTopBar = editingTopBar
        self.editingCutoutTier = editingCutoutTier
        self.startInEditMode = startInEditMode
        self.onBack = onBack
        self.onToggleSidebar = onToggleSidebar
        self.onStatusBarHiddenChange = onStatusBarHiddenChange
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
            bottomChrome
            editingChromeOverlay
        }
        // The WINDOW's inset, not one read from a geometry proxy. A proxy is measured inside this view, and this view
        // adds to its own safe area on the very next line — so the proxy reports the system's band plus the strip we
        // just attached, and because the strip's height feeds `hasCutoutTier` the two chase each other upward.
        // Measured on an iPhone 16 Pro before this was fixed: 62, then 114, then 122, which drew a 62pt cutout band
        // 122pt tall on top of the control tier. See `onWindowTopSafeAreaChange`.
        .onWindowTopSafeAreaChange { topSafeAreaInset = $0 }
        .safeAreaInset(edge: .top) { topBarContent }
        // The cutout tier flanks the display cutout; drawn only where one exists (see
        // `ReaderTopBarLayout.hasCutoutTier`) and only on the overlay so it contributes nothing to the score's inset
        // — the system reserves that band regardless. Empty outside an edit session; while editing, filled with the
        // App-supplied `editingCutoutTier` content (完了 leading, revert trailing) — computed once per pass so both
        // slots read the same value rather than invoking the builder twice.
        .overlay(alignment: .top) {
            if !isCaptureMode, ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: topSafeAreaInset) {
                let editingCutoutContent = isEditing ? editingCutoutTier?(topBarEditingContext) : nil
                ReaderCutoutTier(topSafeAreaInset: topSafeAreaInset) {
                    if let editingCutoutContent {
                        editingCutoutContent.leading
                    }
                } trailing: {
                    if let editingCutoutContent {
                        editingCutoutContent.trailing
                    }
                }
                .ignoresSafeArea(edges: .top)
            }
        }
        .modifier(ReaderHintWiring(
            hints: hints,
            viewModel: viewModel,
            editingHost: editingHost,
            isCaptureMode: isCaptureMode,
            isPDFNoticePresented: $isPDFNoticePresented,
            onStartEditing: editingHost == nil ? nil : { startEditing() },
        ))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // The Reader draws its own top chrome now (`ReaderTopBar`), so the system's navigation bar is hidden
        // unconditionally — capture mode and editing are handled by what `topBarContent` renders, not by toggling
        // the system bar.
        .toolbarVisibility(.hidden, for: .navigationBar)
        // The clock and the battery sit in exactly the two spots the cutout tier wants (leading/trailing, flanking
        // the cutout), so they're cleared only while that tier is actually in use — editing, on a device that has
        // one. On a device with no tier there is nothing to clear and no reason to take the clock away. Hiding the
        // status bar changes no height: the top inset belongs to the cutout and the system keeps reserving it either
        // way (`ReaderTopBarLayout`'s own doc comment). `statusBarHidden(_:)` is the iOS API and is current on iOS
        // 18; the `ToolbarPlacement.statusBar` visibility form is iOS 27 only and is not used here.
        .onChange(of: statusBarShouldHide, initial: true) { _, hide in onStatusBarHiddenChange?(hide) }
        .onDisappear { onStatusBarHiddenChange?(false) }
        // Hiding the navigation bar above also strips its back button, and with it UIKit's own
        // `interactivePopGestureRecognizer` — the compact stack drew a chevron to replace the button, but the
        // edge-swipe gesture doesn't come back on its own. This restores it.
        .restoresInteractivePopGesture()
        // The Reader is a light-appearance screen whatever the system is set to, because its content is: the paper is
        // `Color.white` (both the engraved score and a PDF's pages), and ink is resolved against a light trait before
        // it is even stored (`InkStrokePencilKitBridge.rgba(from:)`). Everything floating over that paper has to match
        // it, and following the system instead did not merely look dark — it came apart:
        //
        // * iOS 26 flips Liquid Glass by the luminance of what is BEHIND it, so in dark mode the navigation bar's
        //   items rendered light over the white score and dark over the scroll background above page 1 — the same
        //   button, two appearances, a scroll apart.
        // * The pad and the transport draw their own `glassEffect`, which does not do that. So the top chrome went
        //   light while the bottom chrome stayed dark, over one sheet of white paper.
        // * Anything stated in absolute ink lost its meaning at the moment the glass under it flipped: the pad
        //   toggle's active state is a dark disc, and over the dark scroll background there was nothing to see.
        //
        // `hostingAppearance` rather than one `preferredColorScheme`, because that one is scoped to the window scene
        // and takes the whole app with it — including the library, which then slid in white for the length of every
        // pop. This one is scoped to this screen's own view controller (and carries the status bar and the
        // UIKit-hosted content, including `ReaderTopBar`, with it). Sheets presented from here are unaffected and
        // come up in the system appearance on their own, which is what the inspectors want. The navigation bar no
        // longer needs its own pin (`toolbarColorScheme`) now that it is hidden rather than shown transparently.
        .hostingAppearance(.light)
        // Attached to the screen, not to the strip's content: a sheet anchored inside `ReaderTopBarControls` would be
        // torn down whenever a `ViewThatFits` candidate swap changes which row renders, or when editing swaps in the
        // App's own chrome.
        .sheet(isPresented: $viewModel.isScoreInfoPresented) {
            EditScoreInfoSheet(model: viewModel, item: viewModel.scoreItem)
                .onAppear { viewModel.analytics.logScreen(.scoreInfo) }
        }
        .sheet(item: $viewModel.shareTarget) { target in
            ActivityViewControllerRepresentable(items: target.urls)
        }
        // The compact-width half of the inspectors: at this width a popover adapts to a sheet anyway, so nothing is
        // lost by presenting it from here — and the strip's buttons stay bare `Button`s, which is what lets them
        // survive being moved into the overflow menu.
        .inspectorSheet(
            isPresented: $viewModel.isPlaybackInspectorPresented,
            enabled: !anchorsInspectorPopovers,
        ) { inspectors.playbackInspector }
        .inspectorSheet(
            isPresented: $viewModel.isVisualInspectorPresented,
            enabled: !anchorsInspectorPopovers,
        ) { inspectors.displayInspector }
        .pdfSourceNoticeAlert(
            originState: viewModel.scoreItem.pdfOriginState,
            isPresented: $isPDFNoticePresented,
            onDontShowAgain: { pdfSourceNoticeDismissed = true },
        )
        .pdfReReadAlerts(viewModel: viewModel, isConfirmPresented: $isReReadConfirmPresented)
        .onChange(of: viewModel.scoreItem.pdfOriginState, initial: true) { _, state in
            // Once per open, as soon as the item's origin is settled — for an item converted on this very open that's
            // after the conversion, not at the start of it. Never for something that didn't come from a PDF.
            guard state != .notPDF, !hasAutoShownPDFNotice, !pdfSourceNoticeDismissed else { return }
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
            // What the Editor addresses (the whole score, hidden staves included) and what the reader has hidden —
            // together these let the host re-stamp IDs between source and rendered addressing. Providers rather than
            // stored values so the host always sees the current visibility without the Reader having to push it.
            editingHost?.sourceScoreProvider = { [weak viewModel, weak editingHost] in
                editingHost?.editedScore ?? viewModel?.loadState.score
            }
            editingHost?.hiddenStavesProvider = { [weak viewModel] in
                viewModel?.layoutModel.hiddenStaves ?? []
            }
            // The write side of the same store, for the Editor's instruments sheet — it lists the score's parts and
            // offers a visibility switch per staff, and this is the one the inspector's own switches call. The hint
            // is retired here for the same reason `StaffVisibilityButton` retires it: the coach mark teaches
            // show/hide-parts, and someone who has just used it from the sheet has plainly found the feature.
            editingHost?.onToggleStaffVisibility = { [weak viewModel] address in
                ReaderHintCoordinator.shared.markUsed(.staffVisibility)
                Task { await viewModel?.layoutModel.toggleStaff(address) }
            }
            // Split out (`ReaderRootScreen+RevertWiring.swift`) to keep this closure — and the struct's primary
            // declaration — under SwiftLint's body-length budgets.
            if let editingHost {
                wireRevertReload(host: editingHost, viewModel: viewModel)
                wirePartRemapReload(host: editingHost, viewModel: viewModel)
            }
            viewModel.playbackSession.startCursorProvider = { [weak editingHost] in
                guard let host = editingHost, host.isEditing,
                      case let .single(item) = host.selection
                else { return nil }
                return .item(item)
            }
            // The score a press of play should catch the engine up with — see
            // `ReaderViewModel.adoptEditedScoreForPlaybackIfStale`. Same pairing as `startCursorProvider` above, and
            // wired here for the same reason: this is where the host and the playback session are both in scope.
            viewModel.editedScoreProvider = { [weak editingHost] in
                guard let host = editingHost, host.isEditing else { return nil }
                return host.editedScore
            }
            pipDisplayOptions.apply(to: viewModel.pipSession)
            await viewModel.load()
            await viewModel.playbackSession.prepareForPlayback()
            // Initial sync: the engine starts up unaware of persisted state, so seed it from the @AppStorage value at
            // view start.
            await viewModel.tempoModel.setMetronomeEnabled(isMetronomeEnabled)
            if startInEditMode {
                startEditing()
            }
            startScreenshotEditingIfRequested()
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepScreenAwake }
        .onAppear { viewModel.analytics.logScreen(.reader) }
        .onDisappear {
            // Anchors describe controls this Reader is drawing; leaving takes them all with it (and any bubble hanging
            // off one). The per-launch hint budget deliberately survives — it belongs to the launch, not the screen.
            hints.clearAllAnchors()
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
        .pdfReReadAlerts(viewModel: viewModel, isConfirmPresented: $isReReadConfirmPresented)
        .onChange(of: viewModel.displaySource) { _, source in
            // Horizontal has no meaning on fixed-layout pages, so switching to the original clamps it — and remembers
            // it, so coming back doesn't silently demote the user's choice. Page and vertical exist on both sides and
            // round-trip untouched, which is the whole reason this is a source switch and not a fourth layout mode.
            switch source {
            case .originalPDF:
                if layoutMode == .horizontal {
                    viewModel.savedScoreLayoutMode = .horizontal
                    layoutModeRaw = ReaderLayoutMode.page.rawValue
                }
            case .score:
                if let saved = viewModel.savedScoreLayoutMode {
                    layoutModeRaw = saved.rawValue
                    viewModel.savedScoreLayoutMode = nil
                }
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
            hints.markUsed(.metronome)
        }
        .onChange(of: pipDisplayOptions) { _, newValue in
            newValue.apply(to: viewModel.pipSession)
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
            if requested {
                finishEditing()
            }
        }
    }

    /// Whether an edit session is running. The Reader yields the whole strip for the duration — its buttons (back /
    /// share / annotate / inspectors) have no meaning over the editing surface — and the App-injected chrome fills
    /// the same strip with the editing controls instead (a later task; see `ReaderTopBar`'s doc comment).
    private var isEditing: Bool {
        editingHost?.isEditing == true
    }

    /// Whether the inspector buttons carry their own popovers. Only at regular width, where the anchor arrow is worth
    /// having and the strip has room to spare; at compact width this screen presents the same content as a sheet
    /// (see `ReaderInspectorDestinations`), which leaves every strip button free of a presentation modifier.
    private var anchorsInspectorPopovers: Bool {
        horizontalSizeClass != .compact
    }

    /// What the inspector buttons open. Built here as well as in `ReaderTopBarControls` so both present identical
    /// content.
    private var inspectors: ReaderInspectorDestinations {
        ReaderInspectorDestinations(
            viewModel: viewModel,
            onConfirmReReadPDF: { isReReadConfirmPresented = true },
        )
    }

    /// The strip's content, or no strip at all in capture mode — screenshot capture wants no chrome eating into the
    /// score, matching what the standard toolbar did today (`toolbarVisibility(.hidden, ...)` removed its inset
    /// contribution entirely). `EmptyView` has no size, so an empty `ReaderTopBar` would still reserve its fixed
    /// control-tier inset per `ReaderTopBarLayout`'s contract — capture mode skips the strip itself, not just its
    /// content, to avoid that. While editing, the App's injected row (`editingTopBar`) renders instead of the
    /// Reader's own controls — `nil` (a Reader with no editing seam) leaves the strip mounted but empty, so its inset
    /// still doesn't move when an edit session starts.
    @ViewBuilder
    private var topBarContent: some View {
        if !isCaptureMode {
            ReaderTopBar(topSafeAreaInset: topSafeAreaInset, isEditing: isEditing) {
                if isEditing {
                    if let editingTopBar {
                        // The inspector goes IN the editing row (`trailingAccessory`), not beside it. Appended
                        // here it sat to the right of 完了, because the editor's row only pushes its own trailing
                        // group to its own edge — and 完了 ends the session, so nothing may come after it.
                        editingTopBar(topBarEditingContext)
                    }
                } else {
                    ReaderTopBarControls(
                        viewModel: viewModel,
                        anchorsInspectorPopovers: anchorsInspectorPopovers,
                        onConfirmReReadPDF: { isReReadConfirmPresented = true },
                        onStartEditing: editingHost == nil ? nil : { startEditing() },
                        onBack: onBack,
                        onToggleSidebar: onToggleSidebar,
                    )
                }
            }
        }
    }

    /// The context handed to `editingTopBar` and `editingCutoutTier` — same type `editingChrome` (the pad overlay)
    /// takes, but this call site is the one that fills in `hasCutoutTier`: only the strip and the cutout tier need
    /// to know which one currently owns 完了 / revert.
    private var topBarEditingContext: ReaderEditingChromeContext {
        ReaderEditingChromeContext(
            bottomTransportClearance: bottomControlContentHeight,
            hasCutoutTier: ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: topSafeAreaInset),
            // The display inspector stays reachable mid-edit — hiding a staff or switching a clef is part of
            // getting the score into a writable shape, and both transforms are edit-compatible. It carries its own
            // glass + shadow because the editor's row controls each carry theirs; the pairing has to match to read
            // as one strip.
            trailingAccessory: AnyView(
                ReaderDisplayInspectorButton(
                    viewModel: viewModel,
                    anchorsInspectorPopovers: anchorsInspectorPopovers,
                    onConfirmReReadPDF: { isReReadConfirmPresented = true },
                )
                .interactiveGlassCompat()
                .shadow(color: .gray.opacity(0.3), radius: 10, y: 5),
            ),
        )
    }

    /// The bottom transport, faded out (opacity + `allowsHitTesting`) while annotating so the reader's mounted playback
    /// state survives the session. Extracted from `body` to keep the outer `ZStack` closure under SwiftLint's
    /// body-length limit.
    private var bottomChrome: some View {
        VStack(spacing: 0) {
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
                ReaderTransportControl(
                    viewModel: viewModel,
                    showSeekBar: showsSeekBarNow,
                    onSetSeekBarVisible: setSeekBarVisible,
                )
                .opacity(viewModel.isAnnotating ? 0 : 1)
                .allowsHitTesting(!viewModel.isAnnotating)
                .animation(.easeOut(duration: 0.2), value: viewModel.isAnnotating)
            }
        }
    }

    /// Applies a swipe on the transport to the persisted `showSeekBar` preference — the same store the Settings sheet
    /// and the visual inspector toggle, so the swipe is just a faster way to flip it and the choice sticks. Returns
    /// whether the change was taken, so the transport knows whether to hold the new mode or animate back to this one.
    ///
    /// Declined while editing: `showsSeekBarNow` forces the compact pill for the edit session, so writing the
    /// preference here would either do nothing visible or silently re-expand the card when editing ends.
    ///
    /// The write itself is DEFERRED until the transport's release animations are over. It flips
    /// `bottomControlContentHeight` (110 ⇄ 44), and in page mode that re-paginates the score — synchronous work heavy
    /// enough to stall the very frames the settle spring and the card morph start on, which read as the control
    /// snagging at the moment the finger lifts. The transport holds the committed mode locally (`previewSeekBar`)
    /// until the preference catches up, so deferring changes nothing the user can see — the reflow just lands on a
    /// scene that has stopped moving. A swipe back inside the window cancels the pending write so only the last
    /// swipe's mode is ever persisted.
    private func setSeekBarVisible(_ visible: Bool) -> Bool {
        guard editingHost?.isEditing != true else { return false }
        // Each direction retires on its own: someone who has found the shrink swipe still has no reason to suspect the
        // pill can be grown back.
        hints.markUsed(visible ? .transportExpand : .transportCollapse)
        seekBarCommitTask?.cancel()
        seekBarCommitTask = Task {
            try? await Task.sleep(for: .seconds(TransportModeSwipe.preferenceCommitDelay))
            guard !Task.isCancelled else { return }
            showSeekBar = visible
        }
        return true
    }

    /// The App-injected editing chrome (note pad, callout — the fixed controls this screen's own strip vacates
    /// while editing are `editingTopBar` / `editingCutoutTier` instead, not this overlay), shown only while
    /// `editingHost.isEditing` and a builder was supplied. `nil` on either side leaves this an empty overlay — the
    /// default, so every existing `ReaderRootScreen` call site (which passes neither) is unaffected.
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
        hints.markUsed(.noteEditing)
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

    /// Screenshot-only: enter edit mode on a freshly loaded score with a note already picked, so the marketing shot
    /// shows the editing surface populated rather than an empty pad. Seeds `pendingSelection` first — that is the same
    /// channel a tap-to-seek uses to carry a target into the session, so the selection arrives through the normal
    /// path instead of a second one built for the camera. See `ReaderScreenshotEditing`.
    ///
    /// The note has to be one the score shows WITHOUT scrolling: a score opens at bar 1 and nothing here can scroll
    /// it. (Parking the transport's cursor on the note doesn't — the surfaces only follow the cursor while it is
    /// running.) So the scene picks a measure inside the opening screenful; a later one leaves the callout clamped at
    /// the bottom edge, pointing at a note that isn't on screen.
    private func startScreenshotEditingIfRequested() {
        guard let measureIndex = ReaderScreenshotEditing.requestedMeasure,
              case let .loaded(score) = viewModel.loadState,
              let host = editingHost
        else { return }
        host.pendingSelection = ReaderScreenshotEditing.firstSoundingNote(inMeasure: measureIndex, of: score)
        startEditing()
    }

    /// Exit edit mode: let the App flush any final edit, adopt the edited score back into the Reader (reloading the
    /// audio engine so playback reflects the new notes — see `ReaderViewModel.adoptEditedScore`), then reset the
    /// host's transient state for the next editing session.
    private func finishEditing() {
        guard let host = editingHost else { return }
        Task {
            host.onEndEditing()
            if let edited = host.editedScore {
                await viewModel.adoptEditedScore(edited)
            }
            host.isEditing = false
            host.selection = .none
            host.caretItem = nil
            host.resetExitRequest()
        }
    }

    /// The score being edited, or `nil` when not editing.
    ///
    /// Three display transforms survive into an edit session:
    ///
    /// * **clef overrides**, because `applying(clefOverrides:)` only REPLACES a staff's opening clef element (or sets
    ///   `defaultClefType`) — it never inserts or removes elements, so every index the editor holds still points at
    ///   the same note. Dropping it made a staff the user had re-clefed jump back to its authored clef the moment
    ///   they started editing it.
    /// * **hidden staves**, because a staff the reader put away has no business coming back — the score visibly
    ///   re-engraved (and, in page mode, re-paginated) on entering edit mode purely to show staves they had chosen
    ///   not to see. This one DOES renumber `StaffAddress`, so it is confined to what is rendered: the Editor keeps
    ///   working on the unfiltered score and `ReaderEditingHost` re-stamps every ID that crosses between the two.
    /// * the **written-pitch view**, because a transposing part is engraved at written pitch — dropping it would flip
    ///   a clarinet's staff back to concert pitch (notes AND key signature) the moment editing started. Like clef
    ///   overrides it only rewrites values in place, never inserting or removing an element, so every index the
    ///   editor holds still points at the same note. It is display-only: the Editor keeps writing into
    ///   `host.editedScore`, which stays concert, and that is what `finishEditing()` adopts and saves.
    ///
    /// Runs through the same `ReaderDisplayTransforms.display` chain as `ReaderViewModel.recomputeVisibleScore`, with
    /// the global transpose pinned to 0 — clef overrides are keyed by full-score address, so they have to land before
    /// the filter renumbers anything.
    ///
    /// Transpose and multi-measure-rest collapse stay off: those renumber ELEMENTS within a staff, which no staff
    /// remap can undo.
    ///
    /// Computed here rather than in `ScoreContentView` so it's rebuilt per edit, not per playback tick.
    private var editingScore: Score? {
        guard let host = editingHost, host.isEditing, let editScore = host.editedScore else { return nil }
        return ReaderDisplayTransforms.display(
            editScore,
            clefOverrides: viewModel.layoutModel.staffClefOverrides,
            transposeSemitones: 0,
            hiddenStaves: viewModel.layoutModel.hiddenStaves,
        )
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
                    showAllMeasureNumbers: showAllMeasureNumbers,
                    autoFollowEnabled: autoFollowEnabled,
                    pageTurnButtonsVisible: pageTurnButtonsVisible,
                    bottomControlContentHeight: bottomControlContentHeight,
                    editingScore: editingScore,
                    editingScoreVersion: editingScoreVersion,
                    editingHost: editingHost,
                )
            }
        }
        // No top reserve for the chrome here: `ReaderTopBar`'s `safeAreaInset(edge: .top)` already contributes it, so
        // only the editing cluster's extra room is added on top.
        .safeAreaPadding(.top, isCaptureMode ? 0 : horizontalEditingInsets.top)
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

// swiftlint:enable type_body_length

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
