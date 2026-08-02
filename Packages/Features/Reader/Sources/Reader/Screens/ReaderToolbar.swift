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

    /// How much of the trailing row has to fold into a single overflow menu at the current width. Decided by
    /// `ReaderRootScreen` from the measured window width and `Metrics` below — a toolbar can't measure itself the way
    /// the old overlay's `ViewThatFits` did.
    var collapse: Collapse = .expanded

    /// Whether the inspector buttons anchor their own popovers. False at compact width, where the screen presents the
    /// same content as a sheet instead — see `ReaderInspectorDestinations` for why the difference matters.
    var anchorsInspectorPopovers = true

    /// Invoked when re-reading the PDF would discard the user's work — `ReaderRootScreen` presents the confirmation.
    /// A re-read with nothing to lose runs straight from the menu item and never reaches here.
    var onConfirmReReadPDF: () -> Void = {}

    /// Invoked when the user taps the "edit notes" button. `nil` hides the button entirely — the default, so previews
    /// and PDF readers (which never wire an `editingHost`) are unaffected.
    var onStartEditing: (() -> Void)?

    /// What the inspector buttons open, resolved from the view model's current state. The screen builds the same value
    /// to present the same content as a sheet at compact width.
    var inspectors: ReaderInspectorDestinations {
        ReaderInspectorDestinations(viewModel: viewModel, onConfirmReReadPDF: onConfirmReReadPDF)
    }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        leadingItems
        if viewModel.displaySource == .originalPDF {
            // Showing the original pages means the PDF chrome, even for an item folino read into notation: the
            // score-side actions (note input, the engraving inspector) have nothing to act on over a fixed-layout page.
            annotationItem
            inspectorItems
        } else if case .loaded = viewModel.loadState {
            scoreActionItems
            noteEditingItem
            annotationItem
            inspectorItems
        } else if case .loadedPDF = viewModel.loadState {
            // No note-editing entry point: a fixed-layout PDF has no score to write into. Ink annotation still applies.
            annotationItem
            inspectorItems
        }
    }

    // MARK: - Leading

    @ToolbarContentBuilder
    private var leadingItems: some ToolbarContent {
        if let leadingAction {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: leadingAction) {
                    Label {
                        leadingIsSidebarToggle
                            ? Text("reader.toolbar.showSidebar", bundle: .module)
                            : Text("reader.toolbar.back", bundle: .module)
                    } icon: {
                        Image(systemName: leadingIsSidebarToggle ? "sidebar.leading" : "chevron.backward")
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        pdfBadgeItem
    }

    // MARK: - Score actions

    /// The "this score" group: score-info (opens the edit-info sheet) + share (lazy format menu), or — when the window
    /// is too narrow — an ellipsis menu that swallows those two first and, on a narrower window still, the note-editing
    /// and annotation entry points after them (see `Collapse`). Sits left of the inspector group so document actions
    /// stay grouped apart from playback/display settings.
    @ToolbarContentBuilder
    private var scoreActionItems: some ToolbarContent {
        if collapse >= .scoreActions {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    scoreInfoButton
                    // Share stays a nested menu so its format list is still loaded lazily, only when opened.
                    ShareSubmenu(
                        loadFormats: { [viewModel] in await viewModel.availableShareFormats() },
                        onShare: { format in
                            Task { await viewModel.requestShare(format: format) }
                        },
                    )
                    if collapse >= .noteEditing, let onStartEditing {
                        Divider()
                        noteEditingButton(action: onStartEditing)
                    }
                    if collapse >= .annotation {
                        annotationToggleButton
                    }
                } label: {
                    // `.labelStyle` on the Menu itself would reach its CONTENT too and strip the titles off every row
                    // inside the menu. It belongs on the label view, here and everywhere else in this file.
                    Label {
                        Text("reader.toolbar.more", bundle: .module)
                    } icon: {
                        Image(systemName: "ellipsis")
                    }
                    .labelStyle(.iconOnly)
                }
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) { scoreInfoButton.labelStyle(.iconOnly) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareFormatMenuItems(
                        loadFormats: { [viewModel] in await viewModel.availableShareFormats() },
                        onShare: { format in
                            Task { await viewModel.requestShare(format: format) }
                        },
                    )
                } label: {
                    Label {
                        Text("reader.toolbar.share", bundle: .module)
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        groupSeparator
    }

    /// Opens the edit-info sheet.
    ///
    /// Every button in this file is built from a `Label` rather than a bare `Image`, and left UNSTYLED: the bar's own
    /// items apply `.iconOnly` at the `ToolbarItem` (rendering the same glyph as before), while the same button placed
    /// inside the overflow menu keeps its title, which is what a menu row needs.
    private var scoreInfoButton: some View {
        Button {
            viewModel.presentScoreInfo()
        } label: {
            Label {
                Text("reader.toolbar.showInfo", bundle: .module)
            } icon: {
                Image(systemName: "info.circle")
            }
        }
    }

    // MARK: - Editing / annotation

    /// The note-editing entry point. In its own group, so it is never mistaken for the annotation toggle beside it —
    /// they write to different things (the score itself vs. ink laid over it). Folds into the overflow menu one step
    /// after the score actions do.
    @ToolbarContentBuilder
    private var noteEditingItem: some ToolbarContent {
        if collapse < .noteEditing, let onStartEditing {
            ToolbarItem(placement: .topBarTrailing) {
                noteEditingButton(action: onStartEditing)
                    .labelStyle(.iconOnly)
                    // Anchored only here, not on the overflow-menu copy: a coach mark points at something visible,
                    // and a folded button has no frame worth pointing at (which also drops the hint — see
                    // `ReaderHintCoordinator.offerRotationHint`).
                    .readerHintAnchor(.noteEditingButton)
            }
            groupSeparator
        }
    }

    private func noteEditingButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text("reader.toolbar.edit.start", bundle: .module)
            } icon: {
                Image(systemName: "square.and.pencil")
            }
        }
    }

    @ToolbarContentBuilder
    private var annotationItem: some ToolbarContent {
        if collapse < .annotation {
            ToolbarItem(placement: .topBarTrailing) {
                annotationToggleButton
                    .labelStyle(.iconOnly)
                    .readerHintAnchor(.annotationButton)
            }
            groupSeparator
        }
    }

    /// Toggles annotation mode. When active, the canvas accepts Pencil/finger input; when inactive, all touches reach
    /// navigation and tap-to-seek. Disabled during playback: entering draw mode hides the transport, which would strand
    /// the user with no visible way to pause — so the toggle is gated until stopped.
    ///
    /// Mode-on reads as the FILLED variant of the same glyph — an outlined pencil tip becomes a solid disc — not as a
    /// different colour and not as a selected background. `.toggleStyle(.button)` was tried and rejected: its bordered
    /// metrics stack on top of the toolbar's own item padding, making this one item visibly wider than its neighbours
    /// and pushing the row over the width at which iOS 26 starts moving items into its own overflow menu. Every item in
    /// the bar is the same width now, so what fits is purely a function of how many items there are — which is what
    /// `Metrics` counts.
    private var annotationToggleButton: some View {
        let isPlaying = viewModel.playbackSession.isPlaying
        let isAnnotating = viewModel.isAnnotating
        return Button {
            ReaderHintCoordinator.shared.markUsed(.annotation)
            viewModel.toggleAnnotation()
        } label: {
            Label {
                Text(
                    isAnnotating ? "reader.toolbar.annotate.stop" : "reader.toolbar.annotate.start",
                    bundle: .module,
                )
            } icon: {
                Image(systemName: isAnnotating ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
            }
        }
        .disabled(isPlaying)
        .animation(.easeOut(duration: 0.2), value: isPlaying)
    }

    // MARK: - Inspectors

    /// Paired playback / visual inspector buttons — adjacent, so iOS 26 renders them as one glass group. They are the
    /// one thing the row never gives up: they are what a player reaches for mid-practice, and keeping them on the bar
    /// is the whole reason anything else folds.
    ///
    /// The playback button is present whenever there is something to play: always for a score — including while its
    /// original pages are showing — and for an unconverted PDF once its background OMR parse lands.
    @ToolbarContentBuilder
    private var inspectorItems: some ToolbarContent {
        if inspectors.playbackScore != nil {
            ToolbarItem(placement: .topBarTrailing) { playbackInspectorButton }
        }
        ToolbarItem(placement: .topBarTrailing) { displayInspectorButton }
    }

    private var playbackInspectorButton: some View {
        Button {
            viewModel.isPlaybackInspectorPresented.toggle()
        } label: {
            Label {
                Text("reader.toolbar.showPlaybackSettings", bundle: .module)
            } icon: {
                Image(systemName: "slider.vertical.3")
            }
            .labelStyle(.iconOnly)
        }
        .readerHintAnchor(.playbackInspectorButton)
        .inspectorPopover(
            isPresented: $viewModel.isPlaybackInspectorPresented,
            anchored: anchorsInspectorPopovers,
        ) { inspectors.playbackInspector }
    }

    private var displayInspectorButton: some View {
        Button {
            viewModel.isVisualInspectorPresented.toggle()
        } label: {
            Label {
                Text("reader.toolbar.showDisplaySettings", bundle: .module)
            } icon: {
                Image(systemName: "text.page")
            }
            .labelStyle(.iconOnly)
        }
        .readerHintAnchor(.visualInspectorButton)
        .inspectorPopover(
            isPresented: $viewModel.isVisualInspectorPresented,
            anchored: anchorsInspectorPopovers,
        ) { inspectors.displayInspector }
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
    let collapse: ReaderToolbar.Collapse
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
                        collapse: collapse,
                        onStartEditing: {},
                    )
                }
                .task { await viewModel.load() }
        }
    }
}

#Preview("Wide · discrete buttons") {
    ReaderToolbarPreviewHost(collapse: .expanded)
}

#Preview("Narrow · collapsed score actions") {
    ReaderToolbarPreviewHost(collapse: .scoreActions)
}

#Preview("Narrower · note editing folded too") {
    ReaderToolbarPreviewHost(collapse: .noteEditing)
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
