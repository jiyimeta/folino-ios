import Domain
import SwiftUI

/// The PDF-side pieces of the reader's top overlay: which rendition is showing, reading the PDF again, and the
/// fixed-layout display inspector that stands in for the score reader's engraving one.
extension ReaderTopOverlay {
    /// The PDF reader's display inspector: a page/vertical layout toggle plus the note about which display adjustments
    /// a fixed-layout PDF can't offer. Stands in for the score reader's visual inspector, which derives its controls
    /// from a rendered `Score`.
    var pdfLayoutButton: some View {
        overlayButton(
            systemImage: "text.page",
            label: Text("reader.toolbar.showDisplaySettings", bundle: .module),
        ) {
            viewModel.isVisualInspectorPresented.toggle()
        }
        .popover(isPresented: $viewModel.isVisualInspectorPresented) {
            PDFLayoutInspectorScreen()
                .frame(idealWidth: 320, idealHeight: 200)
                .presentationDetents([.medium])
                .presentationCompactAdaptation(.sheet)
        }
    }

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

    /// Reads the original PDF again. Sits in the leading cluster rather than the score-side overflow menu because it
    /// has to be reachable from both sides — including from an item folino couldn't read, where it is the retry and
    /// there is no score chrome at all.
    ///
    /// Asks first only when there is something to lose (`reReadNeedsConfirmation`); otherwise it just runs.
    func reReadPDFButton(onConfirm: @escaping () -> Void) -> some View {
        overlayButton(
            systemImage: "arrow.clockwise",
            label: Text("reader.pdf.reread.action", bundle: .module),
        ) {
            if viewModel.reReadNeedsConfirmation {
                onConfirm()
            } else {
                Task { await viewModel.reReadPDF() }
            }
        }
    }
}
