import Domain
import SwiftUI

/// The PDF side of the Reader's toolbar: the actions that only exist because an item came from a PDF, and the inspector
/// group that stands in for the score reader's engraving one while fixed-layout pages are on screen.
extension ReaderToolbar {
    /// Home for the PDF actions that are deliberately not one tap away. Rendered only when there is something in it —
    /// i.e. only for an item that came from a PDF.
    @ToolbarContentBuilder
    var pdfOverflowItem: some ToolbarContent {
        if viewModel.canReReadPDF {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    reReadMenuEntry
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(Text("reader.toolbar.more", bundle: .module))
            }
        }
    }

    /// Re-reads the original PDF, replacing the notation with a fresh parse. Behind a menu rather than given a button
    /// of its own: it is rarely wanted, and on an edited score it throws work away — which is also why it takes the
    /// destructive role and routes through a confirmation exactly when there is something to lose.
    @ViewBuilder
    var reReadMenuEntry: some View {
        if viewModel.canReReadPDF {
            Button(role: viewModel.reReadNeedsConfirmation ? .destructive : nil) {
                if viewModel.reReadNeedsConfirmation {
                    onConfirmReReadPDF()
                } else {
                    Task { await viewModel.reReadPDF() }
                }
            } label: {
                Label {
                    Text("reader.pdf.reread.action", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    /// The PDF reader's inspector group: the playback inspector whenever there is something to play (a converted item
    /// plays from its own score even while the original pages are showing; an unconverted one only once its background
    /// OMR parse lands), plus the PDF layout inspector standing in for the score reader's visual inspector.
    @ToolbarContentBuilder
    var pdfInspectorItems: some ToolbarContent {
        if viewModel.canPlayNow, let score = viewModel.playbackScore {
            ToolbarItem(placement: .topBarTrailing) {
                playbackInspectorButton(score: score, showsStaffVisibility: false)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                viewModel.isVisualInspectorPresented.toggle()
            } label: {
                Image(systemName: "text.page")
            }
            .accessibilityLabel(Text("reader.toolbar.showDisplaySettings", bundle: .module))
            .popover(isPresented: $viewModel.isVisualInspectorPresented) {
                PDFLayoutInspectorScreen()
                    .frame(idealWidth: 320, idealHeight: 200)
                    .presentationDetents([.medium])
                    .presentationCompactAdaptation(.sheet)
            }
        }
    }

    /// Switches between the notation folino read out of the PDF and the original pages. A source switch, not a layout
    /// mode: page and vertical stay available on both sides, so folding it into the mode picker would cost the user
    /// that choice on the original's side. Leading, beside the badge, because it is a one-tap action used often.
    @ToolbarContentBuilder
    var displaySourceItem: some ToolbarContent {
        if viewModel.canShowOriginalPDF {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    viewModel.toggleDisplaySource()
                } label: {
                    Image(systemName: viewModel.displaySource == .score ? "document" : "music.note.list")
                }
                .accessibilityLabel(Text(
                    viewModel.displaySource == .score
                        ? "reader.displaySource.showOriginal"
                        : "reader.displaySource.showScore",
                    bundle: .module,
                ))
            }
        }
    }
}
