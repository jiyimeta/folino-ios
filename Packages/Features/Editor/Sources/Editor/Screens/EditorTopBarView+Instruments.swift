import SwiftUI
import UtilityUI

// The instruments-sheet entry point on the editing strip — the button, the menu row it becomes once the strip folds,
// and the presentation itself. Split out of `EditorTopBarView.swift` to keep that file inside SwiftLint's file-length
// budget, the same reason `EditorTopBarView+Previews.swift` exists.

extension EditorTopBarView {
    /// Opens the instruments sheet — what the score is written for, and which staves are on screen. A plain SF
    /// symbol (`music.note.list`) rather than a custom one: nothing about a list of instruments needs a glyph the
    /// system doesn't already have, and it reads distinctly against the pad toggle's note-with-a-plus next door.
    var instrumentsButton: some View {
        topBarButton(system: "music.note.list", label: "editor.instruments.title") {
            viewModel.isInstrumentsSheetPresented = true
        }
        .interactiveGlassCompat()
    }

    /// `instrumentsButton`'s form once the row has folded into `⋯` — it is the standalone button that goes away at
    /// narrow widths, not the feature.
    var instrumentsMenuRow: some View {
        Button {
            viewModel.isInstrumentsSheetPresented = true
        } label: {
            Label {
                Text("editor.instruments.title", bundle: .module)
            } icon: {
                Image(systemName: "music.note.list")
            }
        }
    }

    /// Presents the sheet from the strip's ROOT, never from whichever control opened it: the entry point moves
    /// between a standalone button and a `Menu` row as the width changes, and a `.sheet` attached to the one that is
    /// currently showing would be torn down — taking the open sheet with it — the moment the fold flipped.
    func instrumentsSheet(on content: some View) -> some View {
        content
            .sheet(isPresented: $viewModel.isInstrumentsSheetPresented) {
                EditorInstrumentsSheet(viewModel: viewModel)
            }
    }
}
