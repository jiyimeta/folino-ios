import SwiftUI

// The key- and time-signature entry points on the editing strip — the two measure-menu rows and the presentations
// they raise. Split out of `EditorTopBarView.swift` for the reason `EditorTopBarView+Instruments.swift` is: that file
// is already at SwiftLint's file-length budget.

extension EditorTopBarView {
    /// Both signature rows, appended to `measureActionRows` — the measure menu is where "what is true of THIS bar"
    /// already lives, and a signature change is exactly that. No standalone button: two more 44pt controls would
    /// push the expanded strip past the narrowest cutout device's width.
    ///
    /// Disabled without a target for the same reason insert-before is: these ops address a bar, and there is none.
    /// The key row is disabled for a kit-only score too — `targetConcertKey` is `nil` when the score has no pitched
    /// staff to read a key from, and a drum part declares none to change.
    @ViewBuilder
    var signatureMenuRows: some View {
        Button {
            viewModel.isKeySignatureSheetPresented = true
        } label: {
            Label {
                Text("editor.measure.keySignature", bundle: .module)
            } icon: {
                Image(systemName: "music.quarternote.3")
            }
        }
        .disabled(viewModel.targetMeasureIndex == nil || viewModel.targetConcertKey == nil)
        Button {
            viewModel.isTimeSignatureSheetPresented = true
        } label: {
            Label {
                Text("editor.measure.timeSignature", bundle: .module)
            } icon: {
                Image(systemName: "metronome")
            }
        }
        .disabled(viewModel.targetMeasureIndex == nil)
    }

    /// Presents both sheets from the strip's ROOT — same reasoning as `instrumentsSheet(on:)`: the rows that open
    /// them live inside a `Menu` that folds in and out as the width changes, and a presentation attached to a control
    /// that can disappear takes the open sheet with it.
    func signatureSheets(on content: some View) -> some View {
        content
            .sheet(isPresented: $viewModel.isKeySignatureSheetPresented) {
                EditorKeySignatureSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isTimeSignatureSheetPresented) {
                EditorTimeSignatureSheet(viewModel: viewModel)
            }
    }
}
