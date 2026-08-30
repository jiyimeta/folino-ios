import ScoreUI
import SwiftUI

// The bar-scoped entry points on the editing strip — the key-signature, time-signature and rehearsal-mark
// measure-menu rows and the presentations they raise. Split out of `EditorTopBarView.swift` for the reason
// `EditorTopBarView+Instruments.swift` is: that file is already at SwiftLint's file-length budget.

extension EditorTopBarView {
    /// The bar-scoped rows — the two signature changes and the rehearsal mark — appended to `measureActionRows`:
    /// the measure menu is where "what is true of THIS bar" already lives, and every one of these is exactly that.
    /// No standalone buttons: three more 44pt controls would push the expanded strip past the narrowest cutout
    /// device's width.
    ///
    /// Disabled without a target for the same reason insert-before is: these ops address a bar, and there is none.
    /// The key row is disabled for a kit-only score too — `targetConcertKey` is `nil` when the score has no pitched
    /// staff to read a key from, and a drum part declares none to change.
    @ViewBuilder
    var measureMenuRows: some View {
        Button {
            viewModel.isKeySignatureSheetPresented = true
        } label: {
            Label {
                Text("editor.measure.keySignature", bundle: .module)
            } icon: {
                // The sharp-and-flat pair the Reader's transpose row already uses — one glyph for "the written
                // pitch moves", wherever it is asked for. Shared through ScoreUI because a Feature cannot reach
                // another Feature's bundle.
                ScoreSymbol.sharpFlat
            }
        }
        .disabled(viewModel.targetMeasureIndex == nil || viewModel.targetConcertKey == nil)
        Button {
            viewModel.isTimeSignatureSheetPresented = true
        } label: {
            Label {
                Text("editor.measure.timeSignature", bundle: .module)
            } icon: {
                // A meter, not a metronome: the tempo is a different control, and this row changes what a bar
                // holds rather than how fast it is played.
                ScoreSymbol.timeSignature
            }
        }
        .disabled(viewModel.targetMeasureIndex == nil)
        Button {
            viewModel.isRehearsalMarkSheetPresented = true
        } label: {
            Label {
                Text("editor.measure.rehearsalMark", bundle: .module)
            } icon: {
                Image(systemName: "a.square")
            }
        }
        .disabled(viewModel.targetMeasureIndex == nil)
    }

    /// Presents all three of the measure menu's sheets from the strip's ROOT — same reasoning as
    /// `instrumentsSheet(on:)`: the rows that open them live inside a `Menu` that folds in and out as the width
    /// changes, and a presentation attached to a control that can disappear takes the open sheet with it.
    func measureMenuSheets(on content: some View) -> some View {
        content
            .sheet(isPresented: $viewModel.isKeySignatureSheetPresented) {
                EditorKeySignatureSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isTimeSignatureSheetPresented) {
                EditorTimeSignatureSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isRehearsalMarkSheetPresented) {
                EditorRehearsalMarkSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isAddMeasuresSheetPresented) {
                EditorAddMeasuresSheet(viewModel: viewModel)
            }
    }
}
