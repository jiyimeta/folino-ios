import Domain
import ScoreUI
import SwiftUI

/// Presents `EditScoreInfoSheet` for the bound item. Mirrors the old rename-alert modifier so each screen wires it
/// with one line.
@MainActor
struct EditScoreInfoSheetModifier: ViewModifier {
    let viewModel: LibraryViewModel
    @Binding var target: ScoreItem?

    func body(content: Content) -> some View {
        content.sheet(item: $target) { item in
            EditScoreInfoSheet(model: viewModel, item: item)
        }
    }
}

extension View {
    @MainActor
    func editScoreInfoSheet(viewModel: LibraryViewModel, target: Binding<ScoreItem?>) -> some View {
        modifier(EditScoreInfoSheetModifier(viewModel: viewModel, target: target))
    }
}
