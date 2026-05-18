import Domain
import SwiftUI
import UtilityUI

/// Rename-score TextField alert for the Library root. Extracted from `LibraryRootScreen` to keep that file under
/// SwiftLint's file-length budget.
@MainActor
struct LibraryRootRenameScoreAlert: ViewModifier {
    let viewModel: LibraryViewModel
    @Binding var pending: ScoreItem?
    @Binding var text: String

    func body(content: Content) -> some View {
        content.alert(
            Text("library.score.rename.title", bundle: .module),
            isPresented: presentationBinding,
            presenting: pending,
        ) { item in
            TextField(text: $text) {
                Text("library.score.rename.placeholder", bundle: .module)
            }
            Button {
                let newTitle = text
                Task { await viewModel.rename(item, to: newTitle) }
            } label: { L10n.Common.save }
            Button(role: .cancel) {} label: { L10n.Common.cancel }
        }
    }

    private var presentationBinding: Binding<Bool> {
        Binding(
            get: { pending != nil },
            set: { isPresented in if !isPresented { pending = nil } },
        )
    }
}

extension View {
    @MainActor
    func libraryRootRenameScoreAlert(
        viewModel: LibraryViewModel,
        pending: Binding<ScoreItem?>,
        text: Binding<String>,
    ) -> some View {
        modifier(LibraryRootRenameScoreAlert(
            viewModel: viewModel,
            pending: pending,
            text: text,
        ))
    }
}
