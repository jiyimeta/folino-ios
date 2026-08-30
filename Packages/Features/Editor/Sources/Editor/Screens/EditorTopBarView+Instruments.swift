import SwiftUI
import UtilityUI

// The instruments-sheet entry point on the editing strip — the button, the menu row it becomes once the strip folds,
// and the presentation itself. Split out of `EditorTopBarView.swift` to keep that file inside SwiftLint's file-length
// budget, the same reason `EditorTopBarView+Previews.swift` exists.

extension EditorTopBarView {
    /// Opens the instruments sheet — what the score is written for, and which staves are on screen.
    ///
    /// A `⋯` row at every width rather than a standalone button that folds into one: the sheet is reached when the
    /// ensemble changes, not while notes are being entered, and the slot it was holding on the strip is worth more
    /// to the controls that are used every bar.
    ///
    /// Named for parts rather than instruments, because that is what the rows are: one per part, carrying its
    /// name, its order, whether its staves are drawn — and, as a secondary line, the instrument it plays. Picking
    /// an instrument only happens on the way to adding a part; no row here changes an existing part's instrument.
    ///
    /// `list.bullet` for the same reason: this is a list to work down, not a picker of instruments. The note-list
    /// glyph it replaced also belongs to the Reader's playlist continuation row, one panel away.
    var instrumentsMenuRow: some View {
        Button {
            viewModel.isInstrumentsSheetPresented = true
        } label: {
            Label {
                Text("editor.instruments.title", bundle: .module)
            } icon: {
                Image(systemName: "list.bullet")
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

// MARK: - The drum pad's key layout

extension EditorTopBarView {
    /// Opens the drum layout sheet. Only ever a `⋯` row, never a standalone button: it is reached rarely — once,
    /// when the shipped fifteen do not match the kit you play — and a strip that spent a slot on it would be
    /// spending it on the wrong thing.
    var drumLayoutMenuRow: some View {
        Button {
            viewModel.isDrumLayoutSheetPresented = true
        } label: {
            Label {
                Text("editor.drum.layout.edit", bundle: .module)
            } icon: {
                Image(systemName: "square.grid.3x2")
            }
        }
    }

    /// Presented from the strip's ROOT for the reason `instrumentsSheet` is: the row that opens it lives inside a
    /// `Menu` that folds with the width, and a sheet attached to it would go with it.
    func drumLayoutSheet(on content: some View) -> some View {
        content
            .sheet(isPresented: $viewModel.isDrumLayoutSheetPresented) {
                EditorDrumLayoutSheet(initial: viewModel.drumPadLayout) { layout in
                    viewModel.setDrumPadLayout(layout)
                    DrumPadLayoutStore.save(layout)
                }
            }
    }
}
