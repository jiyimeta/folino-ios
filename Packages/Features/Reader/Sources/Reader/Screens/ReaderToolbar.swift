import Domain
import ScoreUI
import SheetMusicCore
import SwiftUI
import UtilityUI

/// The Reader's navigation-bar toolbar: the leading affordance (back / sidebar / PDF badge) and the trailing score,
/// editing, annotation and inspector actions.
///
/// This used to be a hand-rolled floating overlay (`ReaderTopOverlay`) drawn inside `ReaderRootScreen`'s `ZStack`,
/// because on iOS 26.3.x devices the navigation bar's chrome could not be suppressed and would have covered the score.
/// Now that the app's audience has moved past that, the same buttons are plain `ToolbarItem`s: the system supplies the
/// Liquid Glass, the placement, the accessibility wiring and the leading back button, while
/// `floatingToolbarBackgroundCompat()` keeps the bar itself transparent so the score still reads through it —
/// maximising the rendered staff area, which is core to the app's value proposition.
struct ReaderToolbar: ToolbarContent {
    @Bindable var viewModel: ReaderViewModel

    /// The leading affordance's action, or `nil` to leave the leading edge to the system back button. Non-nil only
    /// where the system has nothing to offer: the iPad split-view detail, whose leading control reveals the library
    /// column rather than popping a stack.
    let leadingAction: (() -> Void)?

    /// When `true`, `leadingAction` renders as a sidebar-reveal affordance (`sidebar.leading` icon, "show sidebar"
    /// label) rather than a back chevron. Has no effect when `leadingAction` is `nil`.
    var leadingIsSidebarToggle = false

    /// Folds score-info and share into a single overflow menu, saving the one button that pushes the row off a narrow
    /// screen. Decided by `ReaderRootScreen` from the measured window width and `Metrics` below — a toolbar can't
    /// measure itself the way the old overlay's `ViewThatFits` did.
    var collapsesScoreActions = false

    /// Invoked when re-reading the PDF would discard the user's work — `ReaderRootScreen` presents the confirmation.
    /// A re-read with nothing to lose runs straight from the menu item and never reaches here.
    var onConfirmReReadPDF: () -> Void = {}

    /// Invoked when the user taps the "edit notes" button. `nil` hides the button entirely — the default, so previews
    /// and PDF readers (which never wire an `editingHost`) are unaffected.
    var onStartEditing: (() -> Void)?

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        leadingItems
        if viewModel.displaySource == .originalPDF {
            // Showing the original pages means the PDF chrome, even for an item folino read into notation: the
            // score-side actions (note input, the engraving inspector) have nothing to act on over a fixed-layout page.
            annotationItem
            pdfInspectorItems
        } else if case let .loaded(score) = viewModel.loadState {
            scoreActionItems
            noteEditingItem
            annotationItem
            inspectorItems(score: score, showsStaffVisibility: true)
        } else if case .loadedPDF = viewModel.loadState {
            // No note-editing entry point: a fixed-layout PDF has no score to write into. Ink annotation still applies.
            annotationItem
            pdfInspectorItems
        }
    }

    // MARK: - Leading

    @ToolbarContentBuilder
    private var leadingItems: some ToolbarContent {
        if let leadingAction {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: leadingAction) {
                    Image(systemName: leadingIsSidebarToggle ? "sidebar.leading" : "chevron.backward")
                }
                .accessibilityLabel(
                    leadingIsSidebarToggle
                        ? Text("reader.toolbar.showSidebar", bundle: .module)
                        : Text("reader.toolbar.back", bundle: .module),
                )
            }
        }
        pdfBadgeItem
    }

    // MARK: - Score actions

    /// The "this score" group: score-info (opens the edit-info sheet) + share (lazy format menu), or — when the window
    /// is too narrow — both folded into one ellipsis menu. Sits left of the inspector group so document actions stay
    /// grouped apart from playback/display settings.
    @ToolbarContentBuilder
    private var scoreActionItems: some ToolbarContent {
        if collapsesScoreActions {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        viewModel.presentScoreInfo()
                    } label: {
                        Label {
                            Text("reader.toolbar.showInfo", bundle: .module)
                        } icon: {
                            Image(systemName: "info.circle")
                        }
                    }

                    // Share stays a nested menu so its format list is still loaded lazily, only when opened.
                    ShareSubmenu(
                        loadFormats: { [viewModel] in await viewModel.availableShareFormats() },
                        onShare: { format in
                            Task { await viewModel.requestShare(format: format) }
                        },
                    )
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(Text("reader.toolbar.more", bundle: .module))
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.presentScoreInfo()
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel(Text("reader.toolbar.showInfo", bundle: .module))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareFormatMenuItems(
                        loadFormats: { [viewModel] in await viewModel.availableShareFormats() },
                        onShare: { format in
                            Task { await viewModel.requestShare(format: format) }
                        },
                    )
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(Text("reader.toolbar.share", bundle: .module))
            }
        }
        groupSeparator
    }

    // MARK: - Editing / annotation

    /// The note-editing entry point. In its own group, so it is never mistaken for the annotation toggle beside it —
    /// they write to different things (the score itself vs. ink laid over it).
    @ToolbarContentBuilder
    private var noteEditingItem: some ToolbarContent {
        if let onStartEditing {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onStartEditing) {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel(Text("reader.toolbar.edit.start", bundle: .module))
                .readerHintAnchor(.noteEditingButton)
            }
            groupSeparator
        }
    }

    @ToolbarContentBuilder
    private var annotationItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { annotationToggleButton }
        groupSeparator
    }

    /// Toggles annotation mode. When active, the canvas accepts Pencil/finger input; when inactive, all touches reach
    /// navigation and tap-to-seek. Disabled during playback: entering draw mode hides the transport, which would strand
    /// the user with no visible way to pause — so the toggle is gated until stopped.
    ///
    /// Mode-on reads as the FILLED variant of the same glyph — an outlined pencil tip becomes a solid disc — not as a
    /// different colour and not as a selected background. `.toggleStyle(.button)` was tried and rejected: its bordered
    /// metrics stack on top of the toolbar's own item padding, making this one item visibly wider than its neighbours
    /// and pushing the row over the width at which iOS 26 starts moving items into its own overflow menu. Every item in
    /// the bar is now the same width, so the row fits and our own collapse (see `collapsesScoreActions`) stays the only
    /// one that ever runs.
    private var annotationToggleButton: some View {
        let isPlaying = viewModel.playbackSession.isPlaying
        let isAnnotating = viewModel.isAnnotating
        return Button {
            ReaderHintCoordinator.shared.markUsed(.annotation)
            viewModel.toggleAnnotation()
        } label: {
            Image(systemName: isAnnotating ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
        }
        .accessibilityLabel(Text(
            isAnnotating ? "reader.toolbar.annotate.stop" : "reader.toolbar.annotate.start",
            bundle: .module,
        ))
        .readerHintAnchor(.annotationButton)
        .disabled(isPlaying)
        .animation(.easeOut(duration: 0.2), value: isPlaying)
    }

    // MARK: - Inspectors

    /// Paired playback / visual inspector buttons — adjacent, so iOS 26 renders them as one glass group. Each owns its
    /// own popover anchored to itself, so the popover arrow points at the tapped icon.
    @ToolbarContentBuilder
    private func inspectorItems(score: Score, showsStaffVisibility: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            playbackInspectorButton(score: score, showsStaffVisibility: showsStaffVisibility)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                viewModel.isVisualInspectorPresented.toggle()
            } label: {
                Image(systemName: "text.page")
            }
            .accessibilityLabel(Text("reader.toolbar.showDisplaySettings", bundle: .module))
            .readerHintAnchor(.visualInspectorButton)
            .popover(isPresented: $viewModel.isVisualInspectorPresented) {
                VisualInspectorScreen(
                    layoutModel: viewModel.layoutModel,
                    transposeModel: viewModel.transposeModel,
                    score: score,
                    pdfOrigin: pdfOriginControls,
                )
                .frame(idealWidth: 380, idealHeight: 600)
                .presentationDetents([.medium, .large])
                .presentationCompactAdaptation(.sheet)
            }
        }
    }

    /// The PDF reader's inspector group: the playback inspector once the background OMR parse has landed (playback
    /// settings all act on the engine, which plays a parsed PDF exactly as it plays a native score), plus the PDF
    /// layout inspector standing in for the score reader's visual inspector.
    /// The playback-settings button and its popover. Shared by the score reader and — once a PDF's background OMR parse
    /// succeeds — the PDF reader, which passes its parsed score and drops the render-derived staff-visibility eye.
    func playbackInspectorButton(score: Score, showsStaffVisibility: Bool) -> some View {
        Button {
            viewModel.isPlaybackInspectorPresented.toggle()
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .accessibilityLabel(Text("reader.toolbar.showPlaybackSettings", bundle: .module))
        .readerHintAnchor(.playbackInspectorButton)
        .popover(isPresented: $viewModel.isPlaybackInspectorPresented) {
            PlaybackInspectorScreen(
                mixerModel: viewModel.mixerModel,
                layoutModel: viewModel.layoutModel,
                tempoModel: viewModel.tempoModel,
                masterVolumeModel: viewModel.masterVolumeModel,
                a4ReferenceModel: viewModel.a4ReferenceModel,
                repeatModel: viewModel.repeatModel,
                transposeModel: viewModel.transposeModel,
                score: score,
                playbackSession: viewModel.playbackSession,
                isInPlaylist: viewModel.isInPlaylist,
                showsStaffVisibility: showsStaffVisibility,
            )
            .frame(idealWidth: 380, idealHeight: 600)
            .presentationDetents([.large])
            .presentationCompactAdaptation(.sheet)
        }
    }

    /// Breaks the shared glass container between two neighbouring trailing groups, reproducing the gaps the old
    /// overlay drew between its pills. iOS 18 has no grouping to break, so it contributes nothing there.
    @ToolbarContentBuilder
    private var groupSeparator: some ToolbarContent {
        if #available(iOS 26, *) {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
    }
}

extension ReaderToolbar {
    /// What one row of this toolbar costs in width, used by `ReaderRootScreen` to decide whether the score actions fit
    /// as discrete buttons.
    ///
    /// A width breakpoint is the right mechanism here precisely because every trailing item is icon-only: there is no
    /// text to localize and nothing that grows with Dynamic Type, so what the row needs is a function of HOW MANY
    /// items it has and nothing else. What it must not be is a single number for every state — the score reader's six
    /// actions need roughly 160pt more than a PDF's three, and one constant tuned for either is wrong for the other.
    ///
    /// SwiftUI exposes no metric for a toolbar item, so these are measured values, taken from the iOS 26 glass bar
    /// (the wider of the two renderings — iOS 18's bare glyphs are narrower, so deciding on the 26 numbers is the
    /// conservative direction). **Re-measure whenever a button is added to the bar or its item spacing changes.**
    enum Metrics {
        /// One icon-only button, including the spacing the bar puts between items inside a group.
        static let item: CGFloat = 52
        /// The gap a `ToolbarSpacer(.fixed)` opens between two groups.
        static let groupGap: CGFloat = 12
        /// The leading affordance — a bare chevron or the sidebar toggle. Label-less thanks to
        /// `.toolbarRole(.editor)`, so its width is fixed rather than following the previous screen's title.
        static let leading: CGFloat = 44
    }
}

/// A small "PDF" pill shown when the open item is a fixed-layout PDF. The text is a brand literal and is intentionally
/// not localized (iOS/Android parity).
struct PDFBadge: View {
    var body: some View {
        Text(verbatim: "PDF")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18), in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text(verbatim: "PDF"))
    }
}

#if DEBUG
@MainActor
private func previewViewModel() -> ReaderViewModel {
    ReaderViewModel(
        scoreItem: PreviewFakeRepository.sampleItem,
        repository: PreviewFakeRepository(),
        gateway: PreviewFakeGateway(),
        scoresDirectory: URL(filePath: "/tmp"),
    )
}

/// Hosts the toolbar the way `ReaderRootScreen` does — over content, with the bar background left to the OS — so the
/// preview shows what the buttons actually look like floating on a score-coloured backdrop.
private struct ReaderToolbarPreviewHost: View {
    let collapsesScoreActions: Bool
    @State private var viewModel = previewViewModel()

    var body: some View {
        NavigationStack {
            Color(white: 0.97)
                .ignoresSafeArea()
                .navigationTitle("")
                .toolbarTitleDisplayMode(.inline)
                .floatingToolbarBackgroundCompat()
                .toolbar {
                    ReaderToolbar(
                        viewModel: viewModel,
                        leadingAction: nil,
                        collapsesScoreActions: collapsesScoreActions,
                        onStartEditing: {},
                    )
                }
                .task { await viewModel.load() }
        }
    }
}

#Preview("Wide · discrete buttons") {
    ReaderToolbarPreviewHost(collapsesScoreActions: false)
}

#Preview("Narrow · collapsed score actions") {
    ReaderToolbarPreviewHost(collapsesScoreActions: true)
}

#Preview("iPad detail · sidebar toggle") {
    NavigationStack {
        Color(white: 0.97)
            .ignoresSafeArea()
            .navigationTitle("")
            .floatingToolbarBackgroundCompat()
            .toolbar {
                ReaderToolbar(
                    viewModel: previewViewModel(),
                    leadingAction: {},
                    leadingIsSidebarToggle: true,
                )
            }
    }
}
#endif
