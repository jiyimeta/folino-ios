import ScoreUI
import SwiftUI

// The revert confirmation for the strip's FOLDED layout, split out of `EditorTopBarView.swift` for the reason
// `EditorTopBarView+Instruments.swift` is: that file is already at SwiftLint's file-length budget.
//
// `row(collapse: .folded)` mounts `overflowMenu` instead of `endGroup` (`EditorSessionEndButton`), so
// `revertMenuRow` — inside `overflowMenu` — sets `viewModel.isConfirmingRevert = true` with nothing to present it:
// `EditorSessionEndButton` is the only view that carries this popover, and it isn't in the tree in that branch.
// This is a pre-existing bug (folded top bar on an iPhone SE-class phone, or an iPad in Slide Over), not something
// the command-registry work introduced — the menu-bar revert row inherited the same dead path.
//
// `hasCutoutTier` mounts neither branch of `row(collapse:)`, so this is never reachable alongside the cutout
// tier's own `EditorSessionEndButton` (the App's `ReaderEditingCutoutTierContent.trailing`) — attaching a second
// presenter here cannot double-present the one flag both would share.

extension EditorTopBarView {
    /// Presents the same confirmation `EditorSessionEndButton` shows — same message, same action title, same
    /// `revertToOriginal()` call — anchored to `overflowMenu` itself rather than the strip's root: a popover
    /// anchors to the view it decorates (`destructiveConfirmationPopover`'s own doc comment), and the `⋯` control
    /// that raised the request is the right anchor for it, the same way `EditorSessionEndButton` anchors its own
    /// copy to the button that raises IT.
    func revertConfirmationPopover(on content: some View) -> some View {
        content.destructiveConfirmationPopover(
            isPresented: $viewModel.isConfirmingRevert,
            message: viewModel.revertConfirmationMessage(hasMusicalAnnotations: hasMusicalAnnotations),
            actionTitle: Text("editor.revert.confirm.action", bundle: .module),
        ) {
            Task { await viewModel.revertToOriginal() }
        }
    }
}
