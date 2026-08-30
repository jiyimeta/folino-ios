import Domain
import ReaderInteractionCore
import ScoreUI
import SwiftUI
import UtilityUI

/// The Reader's own controls, drawn into `ReaderTopBar`'s control tier: the leading back/sidebar affordance and PDF
/// badge (`ReaderTopBarControls+Leading.swift`), score actions, note editing, annotation, and the paired inspectors.
///
/// The row folds with `ViewThatFits` — see `body`. That is only possible because the strip is a view we draw: a
/// `ToolbarContent` cannot measure itself, so the navigation-bar version of this had to fold by arithmetic against a
/// measured window width instead.
///
/// The inspector pair sits OUTSIDE the `ViewThatFits` ladder on purpose: it never folds, and a candidate swap
/// (rotation, a split-view resize) would otherwise tear down whichever inspector popover is open. A stable sibling —
/// not a child of any candidate row — is what makes `.popover` survive that swap.
struct ReaderTopBarControls: View {
    @Bindable var viewModel: ReaderViewModel

    /// Whether the inspector buttons anchor their own popovers. False at compact width, where `ReaderRootScreen`
    /// presents the same content as a sheet instead — see `ReaderInspectorDestinations` for why the difference
    /// matters.
    var anchorsInspectorPopovers = true

    /// Invoked when re-reading the PDF would discard the user's work. A re-read with nothing to lose runs straight
    /// from the menu item and never reaches here.
    var onConfirmReReadPDF: () -> Void = {}

    /// Invoked when the user taps the "edit notes" button. `nil` hides the button entirely — the default, so previews
    /// and PDF readers (which never wire an `editingHost`) are unaffected.
    var onStartEditing: (() -> Void)?

    /// Pops back to the library. Mirrors `ReaderRootScreen.onBack` — `nil` outside the compact stack, which hides the
    /// chevron. See `leadingAffordance` (`ReaderTopBarControls+Leading.swift`) for why it loses to `onToggleSidebar`
    /// rather than the two ever showing together.
    var onBack: (@MainActor () -> Void)?

    /// Reveals or collapses the library sidebar. Mirrors `ReaderRootScreen.onToggleSidebar` — `nil` outside the
    /// regular split view.
    var onToggleSidebar: (@MainActor () -> Void)?

    /// How much of the trailing row has to fold into a single overflow menu, in the order the row gives things up.
    /// Ordered least to most aggressive, so `collapse >= .noteEditing` reads "note editing has folded". The order IS
    /// the priority statement: score-info and share go first, being read-once document actions; then the
    /// note-editing entry point; then annotation. The two inspectors never fold, which is why they live outside this
    /// ladder entirely (see the type's own doc comment).
    enum Collapse: Int, CaseIterable, Comparable {
        case expanded
        case scoreActions
        case noteEditing
        case annotation

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Which trailing content this state calls for. `nil` while nothing has loaded yet.
    private enum TrailingKind {
        /// The full house: score actions, note editing, annotation, inspectors.
        case full
        /// Annotation + inspectors only — a fixed-layout PDF has nothing for the score-side actions to act on.
        case reduced
    }

    private var trailingKind: TrailingKind? {
        if viewModel.displaySource == .originalPDF {
            return .reduced
        }
        if case .loaded = viewModel.loadState {
            return .full
        }
        if case .loadedPDF = viewModel.loadState {
            return .reduced
        }
        return nil
    }

    private var inspectors: ReaderInspectorDestinations {
        ReaderInspectorDestinations(viewModel: viewModel, onConfirmReReadPDF: onConfirmReReadPDF)
    }

    var body: some View {
        HStack(spacing: 12) {
            leadingAffordance
            pdfBadgeButton
            // `minLength: 0` is what lets `ViewThatFits` fold at all: a greedy spacer would make every candidate
            // report that it fits, and the fold would silently never trigger. Carried across from the old overlay.
            Spacer(minLength: 0)
            // `layoutPriority(1)` pins an allocation this row depends on; it is not decoration.
            // `ViewThatFits` sits here as a SIBLING of the `Spacer` above (and of `inspectorGroup` below) rather
            // than wrapping the whole row the way the old overlay's did — that inversion is what lets the inspector
            // pair stay a stable sibling outside the ladder, so their popovers survive a refold (see the type's doc
            // comment). Without a priority hint, an `HStack` sizes same-tier children least-flexible-first, which in
            // practice already gives `ViewThatFits` the width left after the fixed-width `leadingAffordance` /
            // `inspectorGroup` — a headless `UIHostingController.sizeThatFits` diagnostic against this exact sibling
            // shape (fixed 44pt / 88pt neighbors, a `Spacer(minLength: 0)`, and a four-candidate `ViewThatFits`)
            // picked the same, correctly-folding candidate with and without this modifier at every width tried
            // (350 / 393 / 440pt). `layoutPriority(1)` is still kept — explicitly pinning "the ladder is sized
            // before the `Spacer`" is cheap, matches the old overlay's outer-`ViewThatFits` intent, and removes any
            // dependence on that least-flexible-first tie-breaking continuing to favor `ViewThatFits` over `Spacer`
            // as this row's content changes.
            // Four rungs, but not always four distinct widths: with no `onStartEditing` (a score the Reader cannot
            // open an edit session for) the note-editing button is absent from every rung, so `.scoreActions` and
            // `.noteEditing` measure identically. That is harmless — `ViewThatFits` takes the first candidate that
            // fits either way — and gating the ladder's length on the closure would buy nothing but a branch.
            ViewThatFits(in: .horizontal) {
                row(collapse: .expanded)
                row(collapse: .scoreActions)
                row(collapse: .noteEditing)
                row(collapse: .annotation)
            }
            .layoutPriority(1)
            inspectorGroup
        }
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
    }

    /// One candidate row for `ViewThatFits`. Only the score-actions / note-editing / annotation cluster lives here —
    /// the inspectors are a stable sibling in `body`, not part of any candidate (see the type's doc comment).
    @ViewBuilder
    private func row(collapse: Collapse) -> some View {
        switch trailingKind {
        case .full:
            HStack(spacing: 12) {
                scoreActionsGroup(collapse: collapse)
                if collapse < .noteEditing, let onStartEditing {
                    noteEditingButton(action: onStartEditing)
                        .interactiveGlassCompat()
                }
                if collapse < .annotation {
                    annotationToggleButton
                        .interactiveGlassCompat()
                }
            }
        case .reduced:
            annotationToggleButton
                .interactiveGlassCompat()
        case nil:
            EmptyView()
        }
    }

    // MARK: - Score actions

    /// The "this score" group: score-info (opens the edit-info sheet) + share (lazy format menu), or — once folded —
    /// an ellipsis menu that swallows those two first and, folded further still, the note-editing and annotation
    /// entry points after them.
    @ViewBuilder
    private func scoreActionsGroup(collapse: Collapse) -> some View {
        if collapse >= .scoreActions {
            scoreOverflowMenu(collapse: collapse)
        } else {
            scoreActionButtons()
        }
    }

    private func scoreActionButtons() -> some View {
        HStack(spacing: 0) {
            topBarButton(systemImage: "info.circle", label: Text("reader.toolbar.showInfo", bundle: .module)) {
                viewModel.presentScoreInfo()
            }
            Menu {
                ShareFormatMenuItems(
                    loadFormats: { [viewModel] in await viewModel.availableShareFormats() },
                    onShare: { format in
                        Task { await viewModel.requestShare(format: format) }
                    },
                    companionAction: {
                        Task { await viewModel.requestVocalTunerHandoff() }
                    },
                )
            } label: {
                topBarIcon("square.and.arrow.up")
            }
            .tint(.primary)
            .accessibilityLabel(Text("reader.toolbar.share", bundle: .module))
        }
        .interactiveGlassCompat()
    }

    /// Narrow-width stand-in for `scoreActionButtons()`: score-info and share folded into one ellipsis pill, and —
    /// as the width tightens further — note editing and annotation join it too, in that order.
    private func scoreOverflowMenu(collapse: Collapse) -> some View {
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
            ShareSubmenu(
                loadFormats: { [viewModel] in await viewModel.availableShareFormats() },
                onShare: { format in
                    Task { await viewModel.requestShare(format: format) }
                },
                companionAction: {
                    Task { await viewModel.requestVocalTunerHandoff() }
                },
            )
            if collapse >= .noteEditing, let onStartEditing {
                Divider()
                noteEditingMenuRow(action: onStartEditing)
            }
            if collapse >= .annotation {
                annotationMenuRow
            }
        } label: {
            topBarIcon("ellipsis")
        }
        .tint(.primary)
        .accessibilityLabel(Text("reader.toolbar.more", bundle: .module))
        .interactiveGlassCompat()
    }

    // MARK: - Editing / annotation

    /// The note-editing entry point, shown standalone until it folds into the score-actions overflow menu. The hint
    /// anchor is declared only here, not on the overflow-menu copy: a folded button isn't drawn, so it never reports
    /// a frame for the hint to point at.
    private func noteEditingButton(action: @escaping () -> Void) -> some View {
        topBarButton(
            systemImage: "square.and.pencil",
            label: Text("reader.toolbar.edit.start", bundle: .module),
            action: action,
        )
        .readerHintAnchor(.noteEditingButton)
    }

    private func noteEditingMenuRow(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text("reader.toolbar.edit.start", bundle: .module)
            } icon: {
                Image(systemName: "square.and.pencil")
            }
        }
    }

    /// Mode-on reads as the FILLED variant of the same glyph — an outlined pencil tip becomes a solid disc.
    private var annotationGlyph: String {
        viewModel.isAnnotating ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle"
    }

    private var annotationLabel: Text {
        Text(
            viewModel.isAnnotating ? "reader.toolbar.annotate.stop" : "reader.toolbar.annotate.start",
            bundle: .module,
        )
    }

    /// Toggles annotation mode. When active, the canvas accepts Pencil/finger input; when inactive, all touches
    /// reach navigation and tap-to-seek. Disabled during playback: entering draw mode hides the transport, which
    /// would strand the user with no visible way to pause — so the toggle is gated until stopped.
    private var annotationToggleButton: some View {
        topBarButton(systemImage: annotationGlyph, label: annotationLabel) {
            ReaderHintCoordinator.shared.markUsed(.annotation)
            viewModel.toggleAnnotation()
        }
        .readerHintAnchor(.annotationButton)
        .disabled(viewModel.playbackSession.isPlaying)
        .animation(.easeOut(duration: 0.2), value: viewModel.playbackSession.isPlaying)
    }

    private var annotationMenuRow: some View {
        Button {
            ReaderHintCoordinator.shared.markUsed(.annotation)
            viewModel.toggleAnnotation()
        } label: {
            Label { annotationLabel } icon: { Image(systemName: annotationGlyph) }
        }
        .disabled(viewModel.playbackSession.isPlaying)
    }

    // MARK: - Inspectors

    /// Paired playback / visual inspector buttons, sharing one glass pill — the one thing the row never gives up, and
    /// kept out of the `ViewThatFits` ladder entirely (see `body`) so an open popover survives a fold change. The
    /// playback button is present whenever there is something to play: always for a score — including while its
    /// original pages are showing — and for an unconverted PDF once its background OMR parse lands.
    @ViewBuilder
    private var inspectorGroup: some View {
        if trailingKind != nil {
            HStack(spacing: 0) {
                if inspectors.playbackScore != nil {
                    playbackInspectorButton
                }
                displayInspectorButton
            }
            .interactiveGlassCompat()
        }
    }

    private var playbackInspectorButton: some View {
        topBarButton(
            systemImage: "slider.vertical.3",
            label: Text("reader.toolbar.showPlaybackSettings", bundle: .module),
        ) {
            viewModel.isPlaybackInspectorPresented.toggle()
        }
        .readerHintAnchor(.playbackInspectorButton)
        .inspectorPopover(
            isPresented: $viewModel.isPlaybackInspectorPresented,
            anchored: anchorsInspectorPopovers,
        ) { inspectors.playbackInspector }
    }

    /// Shared with the editing strip — see `ReaderDisplayInspectorButton` for why it is a standalone view.
    private var displayInspectorButton: some View {
        ReaderDisplayInspectorButton(
            viewModel: viewModel,
            anchorsInspectorPopovers: anchorsInspectorPopovers,
            onConfirmReReadPDF: onConfirmReReadPDF,
        )
    }

    // MARK: - Shared button shape

    /// The standalone icon-only button shared by every control in the strip, including the leading affordance drawn
    /// in `ReaderTopBarControls+Leading.swift` — not `private` for that reason.
    func topBarButton(systemImage: String, label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            topBarIcon(systemImage)
        }
        .tint(.primary)
        .accessibilityLabel(label)
    }

    /// The 44×44 tappable glyph shared by the strip's buttons and menus.
    private func topBarIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .medium))
            .frame(width: 44, height: 44)
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

// Both `ViewThatFits` candidates side by side at widths that select them: 375pt folds score-info + share into the
// ellipsis pill; 440pt (iPhone 17 Pro Max) keeps every action a discrete button.
#Preview("Widths") {
    let narrow = previewViewModel()
    let wide = previewViewModel()
    return VStack(spacing: 24) {
        ReaderTopBar { ReaderTopBarControls(viewModel: narrow, onStartEditing: {}) }
            .frame(width: 375)
            .border(.red)
            .task { await narrow.load() }
        ReaderTopBar { ReaderTopBarControls(viewModel: wide, onStartEditing: {}) }
            .frame(width: 440)
            .border(.red)
            .task { await wide.load() }
    }
    .padding(.vertical, 40)
    .background(Color(white: 0.97))
}
#endif
