// PARITY(android): annotation-session strip — while annotating, Android's reader header still shows its reading
//   controls. It owes the same row: ✕ / undo / redo leading, the display inspector and the session-end control
//   trailing (state from the shared `AnnotationSessionEndMode.derive`), with share / info / note editing / the
//   playback inspector hidden for the session, and ✕ restoring the ink the session began with.

import Domain
import ReaderAnnotationCore
import SwiftUI
import UtilityUI

// The strip while an annotation session runs. It follows the editing strip's layout exactly, so the two sessions
// read as the same kind of thing: ✕ leading, undo / redo next to it, the display inspector trailing with the
// session-end control after it — and on a device with a cutout tier, ✕ and the session-end control move up into the
// band, leaving undo / redo and the inspector in the row. Everything the reading strip shows that has no meaning over
// the drawing surface (back, PDF badge, score info, share, note editing, the playback inspector) is gone for the
// duration; the transport is already faded out.

extension ReaderTopBarControls {
    /// The editing strip folds in two rungs and so does this one — see `EditorTopBarView.Collapse` for why two is
    /// the honest number: a `⋯` menu is a 44pt icon, and swapping it for the 44pt checkmark saves nothing, so the
    /// fold can only ever be selected in the clear-all state, where the text pill it replaces is wider.
    enum AnnotationCollapse {
        case expanded
        case folded
    }

    @ViewBuilder
    var annotationRow: some View {
        if hasCutoutTier {
            // ✕ and the session-end control live in the band. What is left — at most undo / redo and the inspector —
            // sits comfortably under the narrowest device that HAS a cutout tier (a 375pt notched phone), so no fold
            // is needed here.
            HStack(spacing: 12) {
                annotationUndoRedoGroup
                Spacer(minLength: 0)
                annotationDisplayInspectorButton
            }
        } else {
            ViewThatFits(in: .horizontal) {
                annotationRow(collapse: .expanded)
                annotationRow(collapse: .folded)
            }
        }
    }

    /// One candidate row for `ViewThatFits`, used only where there is no cutout tier — so this row carries ✕ and the
    /// session-end control itself.
    private func annotationRow(collapse: AnnotationCollapse) -> some View {
        HStack(spacing: 12) {
            AnnotationDiscardButton(viewModel: viewModel)
                .interactiveGlassCompat()
            annotationUndoRedoGroup
            Spacer(minLength: 0)
            // The inspector sits ahead of the session-end control: ✓ ends the session, so nothing comes after it.
            annotationDisplayInspectorButton
            switch collapse {
            case .expanded:
                AnnotationSessionEndButton(viewModel: viewModel)
            case .folded:
                annotationOverflowMenu
                    .interactiveGlassCompat()
            }
        }
    }

    /// Undo + redo, sharing one glass pill, leading — where the editing strip puts the same pair.
    ///
    /// Shown only where the tool picker does not carry its own: PencilKit's palette floats in a regular size class
    /// and shows undo / redo on it, but docks to the bottom in a compact one and drops them (Apple's own PencilKit
    /// sample, `updateLayoutForToolPicker`, and the convention its engineers describe: put them in the app's top bar
    /// when the picker does not show them). The decision is `showsAnnotationUndoRedo`, made by the screen from its
    /// size class — the thing the docking keys off — not from the device, so an iPad in Slide Over gets them too.
    @ViewBuilder
    private var annotationUndoRedoGroup: some View {
        if showsAnnotationUndoRedo {
            HStack(spacing: 0) {
                topBarButton(
                    systemImage: "arrow.uturn.backward",
                    label: Text("reader.annotation.undo", bundle: .module),
                ) {
                    viewModel.annotationCanvasSession.undo()
                }
                .disabled(!viewModel.annotationCanvasSession.canUndo)
                topBarButton(
                    systemImage: "arrow.uturn.forward",
                    label: Text("reader.annotation.redo", bundle: .module),
                ) {
                    viewModel.annotationCanvasSession.redo()
                }
                .disabled(!viewModel.annotationCanvasSession.canRedo)
            }
            .interactiveGlassCompat()
        }
    }

    /// The display inspector stays reachable mid-session, as it does mid-edit: staff size and layout are how the
    /// user gets the score into a shape worth drawing on. Glass of its own here — in the reading strip it shares a
    /// pill with the playback inspector, which is hidden for the session.
    private var annotationDisplayInspectorButton: some View {
        displayInspectorButton
            .interactiveGlassCompat()
    }

    /// Narrow-width stand-in for the session-end control: its clear-all offer (if it is making one) and ✓, folded
    /// into one `⋯`.
    private var annotationOverflowMenu: some View {
        Menu {
            if viewModel.annotationSessionEndMode == .clearAll {
                Button(role: .destructive) {
                    viewModel.isConfirmingAnnotationClear = true
                } label: {
                    Label {
                        Text("reader.annotation.clear.action", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
            }
            Button {
                viewModel.finishAnnotationSession()
            } label: {
                Label {
                    Text("reader.annotation.done.action", bundle: .module)
                } icon: {
                    Image(systemName: "checkmark")
                }
            }
        } label: {
            topBarIcon("ellipsis")
        }
        .tint(.primary)
        .accessibilityLabel(Text("reader.toolbar.more", bundle: .module))
        // The clear-all confirmation is anchored to the session-end button everywhere else; folded, that button is
        // not drawn, so the menu carries it.
        .destructiveConfirmationPopover(
            isPresented: $viewModel.isConfirmingAnnotationClear,
            message: String(localized: "reader.annotation.clear.confirm.body", bundle: .module),
            actionTitle: Text("reader.annotation.clear.action", bundle: .module),
        ) {
            viewModel.clearAllAnnotations()
        }
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

/// Loads the score, then puts the view model into an annotation session in the given state. The ink has to be
/// seeded AFTER `load()`: loading reads the annotation layer back from the (empty) preview store and would replace
/// anything seeded before it.
@MainActor
private func beginAnnotating(_ viewModel: ReaderViewModel, hasInk: Bool = false, hasChanges: Bool = false) async {
    await viewModel.load()
    if hasInk {
        viewModel.annotationDrawings = [DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: Data())]
    }
    viewModel.beginAnnotationSession()
    viewModel.annotationCanvasSession.hasChanges = hasChanges
}

// The strip in every shape an annotation session takes. Top to bottom: a compact phone with no cutout tier (undo /
// redo in the row, all three session-end states); the same at 320pt, where the clear-all pill has to fold into `⋯`;
// and a cutout-tier device's row, where ✕ and the session-end control have moved up into the band.
#Preview("Annotating") {
    let unchanged = previewViewModel()
    let clearAll = previewViewModel()
    let edited = previewViewModel()
    let folded = previewViewModel()
    let cutout = previewViewModel()
    return VStack(spacing: 24) {
        ReaderTopBar { ReaderTopBarControls(viewModel: unchanged, showsAnnotationUndoRedo: true) }
            .frame(width: 393)
            .border(.red)
            .task { await beginAnnotating(unchanged) }
        ReaderTopBar { ReaderTopBarControls(viewModel: clearAll, showsAnnotationUndoRedo: true) }
            .frame(width: 393)
            .border(.red)
            .task { await beginAnnotating(clearAll, hasInk: true) }
        ReaderTopBar { ReaderTopBarControls(viewModel: edited, showsAnnotationUndoRedo: true) }
            .frame(width: 393)
            .border(.red)
            .task { await beginAnnotating(edited, hasInk: true, hasChanges: true) }
        ReaderTopBar { ReaderTopBarControls(viewModel: folded, showsAnnotationUndoRedo: true) }
            .frame(width: 320)
            .border(.red)
            .task { await beginAnnotating(folded, hasInk: true) }
        ReaderTopBar { ReaderTopBarControls(viewModel: cutout, hasCutoutTier: true, showsAnnotationUndoRedo: true) }
            .frame(width: 393)
            .border(.red)
            .task { await beginAnnotating(cutout, hasInk: true, hasChanges: true) }
    }
    .padding(.vertical, 40)
    .background(Color(white: 0.97))
}
#endif
