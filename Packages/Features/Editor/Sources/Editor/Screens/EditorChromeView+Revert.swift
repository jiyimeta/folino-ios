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
                    Text("editor.revert.action", bundle: .module)
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
                Text("editor.revert.confirm.title", bundle: .module),
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
