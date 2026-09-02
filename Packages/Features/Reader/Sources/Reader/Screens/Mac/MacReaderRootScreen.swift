// swiftlint:disable file_length
// MacReaderRootScreen composes the score/PDF content, the transport bar, and the always-open note-editing lifecycle
// seam (`ReaderEditingHost`, design §1/§2); that breadth puts it just over the file_length budget. The budget holds
// until `MacScoreContentView` moves to its own file, a Ⅳb/Ⅳc follow-up.

// PARITY(macos): the Mac reading surface's chrome — this screen renders the score in all three display modes, shows
//   an imported PDF and committed ink, plays them from a transport bar, and edits them from the menu bar and the
//   keyboard. The inspectors, the share / annotate controls, and the score ⇄ original-PDF switch are still iOS-only;
//   see `ReaderRootScreen` for the surface being caught up to.

#if os(macOS)
import Domain
import PDFKit
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
/// What it deliberately does NOT do yet, each owned by a later slice: the inspectors and panels (Ⅳc) and the
/// score ⇄ original-PDF switch (the reader shows whichever rendition `displaySource` names, but has no chrome to
/// change it). The transport is here — `MacTransportBar`, its own sibling of `ReaderTransportControl`.
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
    /// `playbackController` is a real `LivePlaybackController` on macOS now, built by the Mac `AudioStackFactory`
    /// exactly as the iOS one builds its own. It stays optional because `ReaderPlaybackSession` guards every
    /// controller call anyway, which is what lets a preview or a test pass `nil` and get an inert transport.
    ///
    /// `pdfPlaybackParser` is what an imported PDF's on-PDF cursor and click-to-seek are built out of: without it
    /// `loadPDF`'s background parse resolves to `.unavailable` and the document reads as a plain PDF. Optional for the
    /// same reason it is on iOS — a caller with no OMR still gets a working reader.
    ///
    /// `editingHost` is the note-editing seam the composition root fills (`MacEditableReaderScreen`). **The Mac has
    /// no edit mode**: with a host, the session opens the moment the score has loaded and closes when the window
    /// does (design §1). `nil` is a read-only reader, which is what previews and tests get.
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
        pdfPlaybackParser: (any PDFPlaybackParser)? = nil,
        editingHost: ReaderEditingHost? = nil,
        analytics: any Analytics = NoopAnalytics(),
    ) {
        self.editingHost = editingHost
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
                pdfPlaybackParser: pdfPlaybackParser,
                analytics: analytics,
            ),
        )
    }

    /// The mode this screen can actually draw. See `ReaderLayoutMode.macDisplayMode(storedRawValue:)` — the same fold
    /// the View menu's picker resolves its selection with, so the checkmark and the container can never disagree.
    private var layoutMode: ReaderLayoutMode {
        .macDisplayMode(storedRawValue: layoutModeRaw)
    }

    /// The note-editing seam, or `nil` for a read-only reader. Held here (rather than in `MacScoreContentView`) so
    /// `editingScore` below is computed once per this screen's body pass rather than once per read inside the
    /// content view.
    private let editingHost: ReaderEditingHost?

    /// Non-nil only while note editing. The caller has already applied the transforms that rewrite values in place —
    /// clef overrides and the written-pitch view — plus the hidden-staves filter, whose renumbering
    /// `ReaderEditingHost` re-stamps. Raw in every other respect (no global transpose, no collapsed multi-measure
    /// rests) so the element indices the Editor tracks stay valid.
    private var editingScore: Score? {
        ReaderEditingDisplay.score(
            host: editingHost,
            clefOverrides: viewModel.layoutModel.staffClefOverrides,
            hiddenStaves: viewModel.layoutModel.hiddenStaves,
        )
    }

    /// Which edit `editingScore` is. Travels WITH the score (see `MacReaderRootScreen.editingScoreVersion`) so a
    /// container's relayout key can never advance ahead of the score it is keyed to.
    private var editingScoreVersion: Int {
        ReaderEditingDisplay.version(host: editingHost)
    }

    public var body: some View {
        // Two children, and this body reads no playback state of its own: `MacScoreContentView` reads the cursors,
        // and the transport's seek region reads the position, each inside its own body. A tick therefore never
        // reaches this screen. Docking the bar rather than floating it over the score is deliberate — the iOS
        // transport overlays because a phone has no room to spare, and paying for that here would mean insetting
        // every container's viewport to keep the score out from under it.
        VStack(spacing: 0) {
            MacScoreContentView(
                viewModel: viewModel,
                layoutMode: layoutMode,
                collapseMultiMeasureRests: collapseMultiMeasureRests,
                showInvisibleElements: showInvisibleElements,
                showAllMeasureNumbers: showAllMeasureNumbers,
                autoFollowEnabled: autoFollowEnabled,
                editingScore: editingScore,
                editingScoreVersion: editingScoreVersion,
                editingHost: editingHost,
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            MacTransportBar(viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // **This screen pins no appearance at all, and that is a measured decision rather than an omission.**
        //
        // `ReaderRootScreen` pins iOS to light because the Reader's CONTENT is light. That reason covers the paper
        // and what is drawn on it — and on the Mac every one of those things is already a concrete colour, so
        // nothing is left for a pin to protect:
        //
        // * The engraving is `ScoreLayerBuilder.inkColor`, a literal `CGColor(gray: 0, alpha: 1)`; the Canvas
        //   renderers that still say `.color(.primary)` are wrapped by `ScoreView` in its own
        //   `.background(Color.white)` + `.environment(\.colorScheme, .light)`. Two independent guarantees.
        // * Ink is stored as concrete sRGB, resolved against a forced light appearance at capture
        //   (`InkStrokePencilKitBridge.rgba(from:)`) and rebuilt as a plain `NSColor(red:green:blue:alpha:)`.
        // * The title frame draws `.foregroundColor(.black)`; the playback cursor and the AB-loop overlays draw
        //   `.accentColor`, which is one hue in both appearances and legible on white either way.
        // * A PDF page is the document's own ink.
        //
        // What a pin WOULD have caught — the page numbers under the deck, the load spinner, the failure panel, the
        // page-mode scrollers — is chrome standing on the ground, not on the paper. It wants the system appearance,
        // and an adaptive desk is what makes it readable (`MacReaderGround`). Pinning it was over-reach: that came
        // from picking `preferredColorScheme`, which on macOS sets the WINDOW's `NSAppearance`, and so took the
        // library column in the sidebar with it.
        //
        // **One exception, and it is a real one.** Vertical mode paints its paper across the whole scroll view, and
        // AppKit draws the overlay scroller INSIDE that frame — so that one scroller does stand on paper, and in dark
        // appearance a light knob over edge-to-edge white is invisible. It is pinned where it lives, on its own
        // `NSScrollView` (`MacScrollViewAppearance`), which is the scoping this screen could not do for itself.
        // Page mode has no such case: its scroll view shows the desk, not paper.
        .navigationTitle(viewModel.scoreItem.title)
        .task {
            // What the view model is told is the mode this screen actually DRAWS, not the raw preference:
            // `playback_started` must never report a mode that is not on screen. All three modes draw here now, so
            // `layoutMode` substitutes nothing — but it stays the single resolution both this screen and the View
            // menu read, which is what keeps them from disagreeing about an unrecognized stored value.
            viewModel.currentLayoutMode = layoutMode
            viewModel.playbackSession.startObservingCursor()
            viewModel.playbackSession.startObservingSoundfontDownload()
            if let host = editingHost {
                wireEditingSeam(host)
            }
            await viewModel.load()
            await viewModel.playbackSession.prepareForPlayback()
            // Seed the engine from the persisted preference at view start, exactly as the iOS screen does — and it
            // reaches a real engine here now that the Mac builds a `LivePlaybackController`.
            await viewModel.tempoModel.setMetronomeEnabled(isMetronomeEnabled)
            // Design §1: the Mac has no edit mode. The session opens as soon as there is a score to edit, and stays
            // open for the window's lifetime — `endEditing()` in `onDisappear` is the other end.
            beginEditingIfLoaded()
        }
        .onAppear { viewModel.analytics.logScreen(.reader) }
        .onDisappear {
            // Unconditional, unlike iOS: that screen guards this teardown on `scenePhase == .active` because
            // backgrounding an iPad mid-PiP fires `onDisappear` without the user having left the Reader. There is
            // no PiP on the Mac, and closing the window (or switching the detail column to another score) is
            // always a real close.
            let viewModel = viewModel
            // Before the annotation flush and the engine release: `onEndEditing` starts the Editor's own flush, and
            // releasing the engine must not race a save that is still reading the score.
            endEditing()
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
        // Mirror playback state into the seam so the App can put the editing keys to sleep while the cursor runs
        // (design §6.2). Reads `isPlaying`, not the cursor — re-renders on play / pause only, never per tick (same
        // as iOS).
        .onChange(of: viewModel.playbackSession.isPlaying, initial: true) { _, isPlaying in
            editingHost?.isPlaying = isPlaying
        }
        // A revert (`wireRevertReload`) clears the edited score, asks the session to exit, and reloads the file. On
        // iOS that exit ends edit mode; here there is no mode to end, so the session is closed and reopened on the
        // reloaded score. `loadState` is what says the reload landed.
        .onChange(of: editingHost?.isExitRequested ?? false) { _, requested in
            guard requested, let host = editingHost else { return }
            endEditing()
            host.resetExitRequest()
        }
        .onChange(of: viewModel.loadState.isLoaded) { _, loaded in
            if loaded {
                beginEditingIfLoaded()
            }
        }
    }

    /// The Reader-owned half of the editing seam, identical in content to what `ReaderRootScreen.task` installs on
    /// iOS: the addressing providers, the visibility flip, play-from-selection, the edited score for the engine, and
    /// the revert / part-remap reloads.
    private func wireEditingSeam(_ host: ReaderEditingHost) {
        // Design §4.2: the selection IS the playhead while stopped. Selecting puts the displayed cursor away, and
        // `startCursorProvider` below makes Space start from the selected note — the same pairing iOS uses.
        host.onSelectionMade = { [weak viewModel] in
            viewModel?.playbackSession.hideDisplayedCursor()
        }
        // What the Editor addresses (the whole score, hidden staves included) and what the reader has hidden —
        // together these let the host re-stamp IDs between source and rendered addressing.
        host.sourceScoreProvider = { [weak viewModel, weak host] in
            host?.editedScore ?? viewModel?.loadState.score
        }
        host.hiddenStavesProvider = { [weak viewModel] in
            viewModel?.layoutModel.hiddenStaves ?? []
        }
        host.onToggleStaffVisibility = { [weak viewModel] address in
            Task { await viewModel?.layoutModel.toggleStaff(address) }
        }
        viewModel.wireRevertReload(host: host)
        viewModel.wirePartRemapReload(host: host)
        viewModel.playbackSession.startCursorProvider = { [weak host] in
            guard let host, host.isEditing, case let .single(item) = host.selection else { return nil }
            return .item(item)
        }
        // The score a press of play should catch the engine up with — see
        // `ReaderViewModel.adoptEditedScoreForPlaybackIfStale`.
        viewModel.editedScoreProvider = { [weak host] in
            guard let host, host.isEditing else { return nil }
            return host.editedScore
        }
    }

    /// Opens the editing session on the loaded score. A no-op for a PDF-only item or a failed load — there is nothing
    /// to edit — and for a reader built without a host.
    private func beginEditingIfLoaded() {
        guard let host = editingHost, !host.isEditing, case let .loaded(score) = viewModel.loadState else { return }
        host.editedScore = score
        host.editGeneration += 1
        host.isEditing = true
        host.onBeginEditing(score)
    }

    /// Closes the session with the window: the App flushes the autosave and tears the session down. Unlike the iOS
    /// `finishEditing()`, nothing is adopted back into the reader — the window is going away.
    private func endEditing() {
        guard let host = editingHost, host.isEditing else { return }
        host.onEndEditing()
        host.isEditing = false
        host.selection = .none
        host.caretItem = nil
        host.resetExitRequest()
    }
}

/// The live score container plus the load-state switch, extracted from `MacReaderRootScreen.body` so the per-tick
/// playback-cursor reads (`displayCursor` / `scrollAnchorCursor`) stay scoped to THIS view's body.
///
/// The iOS `ScoreContentView` exists for the same reason and its doc comment carries the measurement: read at the
/// root, those cursors re-rendered the whole screen on every tick during playback.
///
/// **This boundary is load-bearing, not speculative.** `MacTransportBar` drives a real engine now, so a cursor tick
/// arrives at the Mac reader on every step of playback — moving either read up into `MacReaderRootScreen.body` would
/// rebuild the whole screen at the engine's tick rate. The transport's own half of the same boundary is
/// `MacSeekRegion`, which is where the live position is read.
struct MacScoreContentView: View {
    let viewModel: ReaderViewModel
    /// Already normalized to a mode the Mac can draw — see `MacReaderRootScreen.layoutMode`.
    let layoutMode: ReaderLayoutMode
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let showAllMeasureNumbers: Bool
    let autoFollowEnabled: Bool

    /// Non-nil only while note editing. The caller has already applied the transforms that rewrite values in place —
    /// clef overrides and the written-pitch view — plus the hidden-staves filter, whose renumbering
    /// `ReaderEditingHost` re-stamps. Raw in every other respect (no global transpose, no collapsed multi-measure
    /// rests) so the element indices the Editor tracks stay valid.
    let editingScore: Score?
    /// Which edit `editingScore` is. Travels WITH the score (see `MacReaderRootScreen.editingScoreVersion`) so a
    /// container's relayout key can never advance ahead of the score it is keyed to.
    let editingScoreVersion: Int
    /// The note-editing seam, or `nil` for a read-only reader. Mirrors the iOS `ScoreContentView`: whether the
    /// reader is editing changes only the containers' INPUTS — which score, and whether the element-renumbering
    /// display transforms apply — never which container is mounted, so the laid-out document survives an edit.
    let editingHost: ReaderEditingHost?

    /// The score the containers render: the editing score while editing, the display-transformed one otherwise.
    private var renderedScore: Score? {
        editingScore ?? viewModel.visibleScore
    }

    private var isEditing: Bool {
        editingScore != nil
    }

    /// Multi-measure-rest collapse renumbers elements within a staff, which no staff remap can undo — off while
    /// editing, exactly as on iOS.
    private var effectiveCollapseMultiMeasureRests: Bool {
        isEditing ? false : collapseMultiMeasureRests
    }

    private var effectiveTransposeSemitones: Int {
        isEditing ? 0 : viewModel.transposeModel.effectiveSemitones
    }

    var body: some View {
        // The original PDF wins over whatever the load state holds — the same condition `ScoreContentView` branches
        // on, and it is a display-source question, not a load-state one: for an item folino read OUT of a PDF both
        // renditions exist at once and `displaySource` picks between them, while an item folino could not read has
        // only the original and `loadPDF` sets the same source. One condition covers both.
        if viewModel.displaySource == .originalPDF, let document = viewModel.originalPDFDocument {
            originalPDF(document: document)
        } else {
            loadStateContent
        }
    }

    @ViewBuilder
    private var loadStateContent: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView().controlSize(.large)
        case .loaded:
            if let score = renderedScore {
                scoreContainer(score: score)
            } else {
                ProgressView().controlSize(.large)
            }
        case let .loadedPDF(document):
            originalPDF(document: document)
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

    /// The mode branch. Every container takes the cursors as VALUES, read here — one level below the root — so a
    /// per-tick cursor change re-renders the container and the leaves beneath it and never `MacReaderRootScreen`.
    @ViewBuilder
    private func scoreContainer(score: Score) -> some View {
        switch layoutMode {
        case .page:
            MacPagedScoreContainer(
                score: score,
                staffSize: viewModel.layoutModel.effectiveStaffSize,
                honorLayoutBreaks: viewModel.layoutModel.effectiveHonorLayoutBreaks,
                collapseMultiMeasureRests: effectiveCollapseMultiMeasureRests,
                showInvisibleElements: showInvisibleElements,
                showAllMeasureNumbers: showAllMeasureNumbers,
                playbackCursor: viewModel.playbackSession.displayCursor,
                pageAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,
                autoFollowEnabled: autoFollowEnabled,
                transposeSemitones: effectiveTransposeSemitones,
                editingScoreVersion: editingScoreVersion,
                viewModel: viewModel,
                editingHost: editingHost,
            )
        case .horizontal:
            MacHorizontalScoreContainer(
                score: score,
                staffSize: viewModel.layoutModel.effectiveStaffSize,
                honorLayoutBreaks: viewModel.layoutModel.effectiveHonorLayoutBreaks,
                collapseMultiMeasureRests: effectiveCollapseMultiMeasureRests,
                showInvisibleElements: showInvisibleElements,
                showAllMeasureNumbers: showAllMeasureNumbers,
                playbackCursor: viewModel.playbackSession.displayCursor,
                scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,
                autoFollowEnabled: autoFollowEnabled,
                transposeSemitones: effectiveTransposeSemitones,
                editingScoreVersion: editingScoreVersion,
                viewModel: viewModel,
                editingHost: editingHost,
            )
        case .vertical:
            MacVerticalScoreContainer(
                score: score,
                staffSize: viewModel.layoutModel.effectiveStaffSize,
                honorLayoutBreaks: viewModel.layoutModel.effectiveHonorLayoutBreaks,
                collapseMultiMeasureRests: effectiveCollapseMultiMeasureRests,
                showInvisibleElements: showInvisibleElements,
                showAllMeasureNumbers: showAllMeasureNumbers,
                playbackCursor: viewModel.playbackSession.displayCursor,
                scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,
                autoFollowEnabled: autoFollowEnabled,
                transposeSemitones: effectiveTransposeSemitones,
                editingScoreVersion: editingScoreVersion,
                viewModel: viewModel,
                editingHost: editingHost,
            )
        }
    }

    /// The imported document itself. Reads the on-PDF cursor here, one level below the root, for the same reason the
    /// score containers take theirs as a value: a per-tick read at `MacReaderRootScreen` would rebuild the screen.
    ///
    /// `pdfDisplayCursorRect` is `nil` until the background OMR parse lands (and forever if it fails), which is
    /// exactly what should happen — no geometry, no cursor — and the click below resolves to nothing for the same
    /// reason, leaving the document a plain reader.
    ///
    /// No ground is applied here: `PDFView` paints its own opaque background, and that is the desk (see
    /// `MacOriginalPDFView.makeNSView`). A SwiftUI `.background` behind it would be dead pixels and a second source
    /// of truth for the same colour.
    private func originalPDF(document: PDFDocument) -> some View {
        MacOriginalPDFView(
            document: document,
            cursorRect: viewModel.pdfDisplayCursorRect,
            followsCursor: autoFollowEnabled,
            annotations: viewModel.annotationDrawings,
            onClick: { pageIndex, point in
                guard let cursor = viewModel.pdfPlaybackData?.geometry.cursor(at: point, pageIndex: pageIndex)
                else { return }
                viewModel.playbackSession.setManualCursor(cursor)
            },
        )
    }
}
#endif
