import Domain
import SwiftUI

extension ReaderTopOverlay {
    /// Switches between the notation folino read out of the PDF and the original pages. A source switch, not a layout
    /// mode: page and vertical stay available on both sides, so folding it into the mode picker would cost the user
    /// that choice on the original's side.
    ///
    /// Shown only for an item whose PDF folino actually read — one it couldn't read has nothing to switch to, and an
    /// item that never came from a PDF has no original at all.
    func displaySourceToggle() -> some View {
        overlayButton(
            systemImage: viewModel.displaySource == .score ? "document" : "music.note.list",
            label: viewModel.displaySource == .score
                ? Text("reader.displaySource.showOriginal", bundle: .module)
                : Text("reader.displaySource.showScore", bundle: .module),
        ) {
            viewModel.toggleDisplaySource()
        }
    }
}
