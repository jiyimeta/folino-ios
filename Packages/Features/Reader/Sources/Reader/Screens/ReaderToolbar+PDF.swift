import Domain
import SwiftUI

/// The PDF side of the Reader's toolbar: the badge shown while the original pages are up, and the inspector group that
/// stands in for the score reader's engraving one.
extension ReaderToolbar {
    /// The "PDF" badge, shown only while the original pages are on screen — that is the one place it says something
    /// the user can't already see. It stays a badge, not a button: no border, no tint, nothing that reads as a
    /// control. It is tappable all the same, and opens the two actions that belong to a PDF-derived item.
    ///
    /// No explanatory header: the notice's text points at the note-editing button, which isn't on screen while the
    /// original pages are. The explanation lives in the notice itself and in the display inspector's PDF section.
    ///
    /// This is also why the badge doesn't need to compete for width: the note-input button is gone while a
    /// fixed-layout page is showing, so the row has room for it.
    @ToolbarContentBuilder
    var pdfBadgeItem: some ToolbarContent {
        if viewModel.displaySource == .originalPDF, ScorePresentation.showsPDFBadge(for: viewModel.scoreItem) {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    showScoreMenuEntry
                    reReadMenuEntry
                } label: {
                    PDFBadge()
                }
                .buttonStyle(.plain)
                .menuStyle(.button)
                .menuIndicator(.hidden)
            }
        }
    }

    /// Switches back to the notation folino read out of the PDF. One-directional on purpose: this lives in a menu that
    /// only exists while the original pages are showing, so there is no state in which it would mean the reverse.
    @ViewBuilder
    var showScoreMenuEntry: some View {
        if viewModel.canShowOriginalPDF {
            Button {
                viewModel.setDisplaySource(.score)
            } label: {
                Label {
                    Text("reader.displaySource.showScore", bundle: .module)
                } icon: {
                    Image(systemName: "music.note.list")
                }
            }
        }
    }

    /// Re-reads the original PDF, replacing the notation with a fresh parse. It is rarely wanted, and on an edited
    /// score it throws work away — hence the destructive role and the confirmation, taken exactly when there is
    /// something to lose.
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

    /// The PDF controls the display inspector carries, or `nil` for an item that never came from a PDF — which hides
    /// the whole section. This is where the score side keeps them: with the badge gone once the notation is showing,
    /// the inspector is the one place that still says "this came from a PDF, and here is what you can do about it".
    var pdfOriginControls: PDFOriginControls? {
        guard viewModel.scoreItem.pdfOriginState != .notPDF else { return nil }
        return PDFOriginControls(
            showsOriginalPDF: viewModel.displaySource == .originalPDF,
            setShowsOriginalPDF: viewModel.canShowOriginalPDF
                ? { showsOriginal in viewModel.setDisplaySource(showsOriginal ? .originalPDF : .score) }
                : nil,
            reParse: viewModel.canReReadPDF
                ? {
                    if viewModel.reReadNeedsConfirmation {
                        onConfirmReReadPDF()
                    } else {
                        Task { await viewModel.reReadPDF() }
                    }
                }
                : nil,
        )
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
                PDFLayoutInspectorScreen(pdfOrigin: pdfOriginControls)
                    .frame(idealWidth: 320, idealHeight: 320)
                    .presentationDetents([.medium])
                    .presentationCompactAdaptation(.sheet)
            }
        }
    }
}
