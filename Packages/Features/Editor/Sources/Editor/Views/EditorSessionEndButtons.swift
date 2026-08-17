import SwiftUI

// 完了 and revert — the two controls that end an editing session (design spec, "the two spots Photos uses for the
// same purpose"). Shared, public types rather than private pieces of `EditorTopBarView` because the App mounts them
// in TWO separate places depending on the device: the Reader's own `ReaderCutoutTier` (via
// `ReaderRootScreen.editingCutoutTier`) on a device with one, or inline in `EditorTopBarView`'s own control-tier row
// where there isn't (review Important 4 — the Reader owns the real cutout-tier layout code, not a re-declared
// copy).
//
// Both read `EditorViewModel` directly rather than taking `onDone` / a revert action as a second escaping closure
// (only `onDone` is truly external — see `EditorDoneButton`), so the same instance can be constructed independently
// in the Reader's tree and in `EditorTopBarView`'s without either side threading extra plumbing through
// `ReaderEditingChromeContext`.

/// Ends the session. `onDone` is still a closure (not a view-model call) because ending the session is the Reader's
/// call to make — it routes through `ReaderEditingHost.requestExit()`, which this package cannot see.
public struct EditorDoneButton: View {
    let onDone: () -> Void

    public init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    public var body: some View {
        Button(action: onDone) {
            Text("editor.chrome.done", bundle: .module)
                .fontWeight(.semibold)
        }
        .tint(.primary)
        // Own minimum hit target rather than relying on a caller's `.frame` — `EditorTopBarView`'s control-tier
        // mount adds `minWidth: 60, minHeight: 44`, but `ReaderRootScreen.editingCutoutTier`'s cutout-tier mount
        // uses this button raw. Without this, 完了 there sits under the 44pt minimum, in the band that's hardest to
        // hit (review Minor 1).
        .frame(minHeight: 44)
    }
}

/// Raises the revert confirmation. Empty when there is nothing to revert to — callers never need to guard
/// `canRevertToOriginal` themselves. The confirmation dialog itself is NOT here: it lives on
/// `EditorTopBarView`'s stable root, the one place guaranteed to survive both a `ViewThatFits` refold and a
/// cutout-tier toggle, and reads `viewModel.isConfirmingRevert` — the same flag this button sets — to know when to
/// present.
public struct EditorRevertButton: View {
    @Bindable var viewModel: EditorViewModel

    public init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if viewModel.canRevertToOriginal {
            Button(role: .destructive) {
                viewModel.isConfirmingRevert = true
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .tint(.primary)
            .accessibilityLabel(Text(
                viewModel.revertsToConversionOutput ? "editor.revert.action.pdf" : "editor.revert.action",
                bundle: .module,
            ))
        }
    }
}

#if DEBUG
@MainActor
private func previewViewModel(canRevert: Bool) -> EditorViewModel {
    let viewModel = PreviewEditorFactory.makeViewModel()
    if canRevert {
        viewModel.scoreItem = viewModel.scoreItem.capturingOriginal(
            fileName: "preview.original.mscx", contentHash: "preview-original", provenance: .importTime,
        )
        viewModel.hasCapturedOriginal = true
    }
    return viewModel
}

// The shape `ReaderRootScreen.editingCutoutTier` mounts on a device with a cutout tier: 完了 leading, revert
// trailing, nothing in between — the cutout's width varies by model and neither button may assume how much room
// the middle has.
#Preview("Cutout tier shape") {
    HStack {
        EditorDoneButton(onDone: {})
        Spacer(minLength: 0)
        EditorRevertButton(viewModel: previewViewModel(canRevert: true))
    }
    .padding(.horizontal)
    .frame(height: 59)
    .background(Color(white: 0.97))
}
#endif
