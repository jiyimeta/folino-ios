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
