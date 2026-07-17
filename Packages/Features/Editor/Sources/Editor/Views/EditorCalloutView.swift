import SwiftUI

/// The compact-width (iPhone) contextual callout: a horizontal Liquid Glass capsule of the shared `EditorContextOps`
/// buttons plus a trailing `⋯` menu that hosts the voice picker (spec §5.4/§5.7). Positioning — converting the global
/// `selectionAnchor` into local space and clamping it on-screen — is the parent `EditorChromeView`'s job; this view
/// only draws the capsule. It is only ever mounted while a selection exists, so it needs no empty state.
struct EditorCalloutView: View {
    let viewModel: EditorViewModel

    /// Height of the divider separating the ops from the overflow menu.
    private static let dividerHeight: CGFloat = 28

    var body: some View {
        HStack(spacing: 4) {
            EditorContextOps.buttons(viewModel: viewModel)

            Divider().frame(height: Self.dividerHeight)

            Menu {
                EditorVoicePicker(viewModel: viewModel)
            } label: {
                EditorContextOps.symbolGlyph("ellipsis")
                    .frame(minWidth: 40, minHeight: 44)
            }
            .tint(.primary)
            .accessibilityLabel(Text("editor.voice.label", bundle: .module))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular.interactive())
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
    }
}
