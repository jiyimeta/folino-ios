import Domain
import ScoreUI
import SwiftUI
import UtilityUI

/// The strip's leading cluster — everything left of the spacer in `ReaderTopBarControls.body`: the back/sidebar
/// affordance, then the PDF badge menu. Split out of `ReaderTopBarControls.swift` to keep that file under
/// SwiftLint's line-length budget; both pieces only need `viewModel` and the closures already stored there.
extension ReaderTopBarControls {
    // MARK: - Leading affordance

    /// The strip's leading control: the split-view sidebar toggle when supplied, else the compact stack's back
    /// chevron, else nothing. The toggle wins whenever it's supplied — not just while the sidebar is hidden — so it
    /// can also collapse an already-open one; the two are never supplied at once (`ReaderRootScreen.onBack` /
    /// `.onToggleSidebar` each belong to a different layout), so there is no case where both would need to show.
    @ViewBuilder
    var leadingAffordance: some View {
        if let onToggleSidebar {
            topBarButton(
                systemImage: "sidebar.leading",
                label: Text("reader.toolbar.toggleSidebar", bundle: .module),
                action: onToggleSidebar,
            )
        } else if let onBack {
            topBarButton(
                systemImage: "chevron.backward",
                label: Text("reader.toolbar.back", bundle: .module),
                action: onBack,
            )
        }
    }

    // MARK: - PDF badge

    /// The "PDF" badge, shown only while the original pages are on screen — that is the one place it says something
    /// the user can't already see. It stays a badge, not a button: no border, no tint, nothing that reads as a
    /// control. It is tappable all the same, and opens the two actions that belong to a PDF-derived item.
    @ViewBuilder
    var pdfBadgeButton: some View {
        if viewModel.displaySource == .originalPDF, ScorePresentation.showsPDFBadge(for: viewModel.scoreItem) {
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

    /// Switches back to the notation folino read out of the PDF. One-directional on purpose: this lives in a menu
    /// that only exists while the original pages are showing, so there is no state in which it would mean the
    /// reverse.
    @ViewBuilder
    private var showScoreMenuEntry: some View {
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
    private var reReadMenuEntry: some View {
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
}
