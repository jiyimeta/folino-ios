import Domain
import SwiftUI

extension EditorChromeView {
    /// Folded into a `⋯` menu rather than added as a sixth bar item on purpose. The row already runs five items
    /// wide, and iOS 26 collapses a bar it cannot fit into an overflow menu of its own choosing — which would take
    /// undo and redo with it. Choosing what folds beats being folded.
    var overflowMenu: some View {
        Menu {
            Button(role: .destructive) {
                isConfirmingRevert = true
            } label: {
                Label {
                    // A PDF-origin sidecar is the conversion's output, not the file the user imported — the imported
                    // PDF is a separate original sitting in the same sheet, so this must not call the sidecar "the
                    // original" a second time (design spec, "Two originals must never be called the same thing";
                    // Important 5 review fix).
                    Text(
                        viewModel.revertsToConversionOutput ? "editor.revert.action.pdf" : "editor.revert.action",
                        bundle: .module,
                    )
                } icon: {
                    Image(systemName: "arrow.counterclockwise")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(Text("editor.chrome.more", bundle: .module))
    }

    /// The confirmation. Destructive and not undoable, so it names what goes and what stays, and adds the caveat
    /// for an item whose recorded original predates the feature.
    func revertConfirmation(on content: some View) -> some View {
        content
            .confirmationDialog(
                Text(
                    viewModel.revertsToConversionOutput
                        ? "editor.revert.confirm.title.pdf" : "editor.revert.confirm.title",
                    bundle: .module,
                ),
                isPresented: $isConfirmingRevert,
                titleVisibility: .visible,
            ) {
                Button(role: .destructive) {
                    Task { await viewModel.revertToOriginal() }
                } label: {
                    Text("editor.revert.confirm.action", bundle: .module)
                }
                Button(role: .cancel) {} label: {
                    Text("editor.revert.confirm.cancel", bundle: .module)
                }
            } message: {
                Text(revertMessage)
            }
            // A revert that fails silently is worse than the dialog it replaced: the confirmation closes either way,
            // so without this the user has no way to tell "reverted" apart from "the store threw and nothing
            // happened". `revertError` is cleared on dismiss so a later successful revert can't re-show a stale alert.
            .alert(
                Text("editor.revert.failed", bundle: .module),
                isPresented: isRevertErrorPresented,
            ) {
                Button {
                    viewModel.revertError = nil
                } label: {
                    Text("editor.revert.failed.dismiss", bundle: .module)
                }
            } message: {
                // Without this, `revertError`'s localized string is computed and stored but never shown — the alert
                // reads identically to a successful revert's silence, undoing the point of surfacing an error at
                // all (Minor review fix).
                Text(viewModel.revertError ?? "")
            }
    }

    private var isRevertErrorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.revertError != nil },
            set: { isPresented in
                if !isPresented { viewModel.revertError = nil }
            },
        )
    }

    private var revertMessage: String {
        let warnings = viewModel.revertWarnings(hasMusicalAnnotations: hasMusicalAnnotations)
        var lines = [String(localized: "editor.revert.confirm.body", bundle: .module)]
        if warnings.contains(.musicalAnnotationsMayShift) {
            lines.append(String(localized: "editor.revert.confirm.inkMayShift", bundle: .module))
        }
        if warnings.contains(.originalMayNotBeImportTime) {
            lines.append(String(localized: "editor.revert.confirm.mayNotBeImport", bundle: .module))
        }
        return lines.joined(separator: "\n\n")
    }
}
