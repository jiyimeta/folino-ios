import Domain
import ScoreUI
import SwiftUI

/// The key in force at the target bar, editable. Everything structural lives in `EditorSignatureSheet`; this supplies
/// the circle-of-fifths picker and the four strings that make it about keys.
@MainActor
struct EditorKeySignatureSheet: View {
    let viewModel: EditorViewModel
    /// The picked key, seeded once from what is in force at the target bar. `@State` rather than a computed binding
    /// on the view model: turning the wheel must not write the score — Apply is what writes it.
    ///
    /// C major is the seed for a score with no key to read (a kit-only one). The row that opens this sheet is
    /// disabled in exactly that case, so the fallback is a compiler obligation rather than a state a user can reach.
    @State private var concertKey: Int

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
        _concertKey = State(initialValue: viewModel.targetConcertKey ?? 0)
    }

    var body: some View {
        EditorSignatureSheet(
            viewModel: viewModel,
            title: "editor.signature.key.title",
            currentValue: KeySignatureLabel.label(for: viewModel.targetConcertKey ?? concertKey),
            hasExplicitChange: viewModel.targetHasExplicitKeyChange,
            removalMessage: "editor.signature.remove.message.key",
            apply: { viewModel.setKeySignature(concertKey: concertKey) },
            remove: { viewModel.removeKeySignatureChange() },
        ) {
            KeySignaturePicker(selection: $concertKey)
        }
    }
}

#if DEBUG
#Preview("Key — mid-piece change") {
    EditorSignatureSheetPreviews.keySheet(targetingBarWithChange: true)
}

#Preview("Key — inherited") {
    EditorSignatureSheetPreviews.keySheet(targetingBarWithChange: false)
}
#endif
