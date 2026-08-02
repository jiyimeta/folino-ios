import SwiftUI
import UtilityUI

extension View {
    /// The two alerts that bracket re-reading a PDF: the confirmation before folino throws away work the user did on
    /// top of the previous read, and the report when the PDF couldn't be read at all.
    ///
    /// The confirmation is presented only when there is something to lose — the toolbar button decides that via
    /// `reReadNeedsConfirmation` and runs the re-read directly otherwise, so a clean item never sees a dialog.
    func pdfReReadAlerts(
        viewModel: ReaderViewModel,
        isConfirmPresented: Binding<Bool>,
    ) -> some View {
        alert(
            Text("reader.pdf.reread.confirm.title", bundle: .module),
            isPresented: isConfirmPresented,
        ) {
            Button(role: .cancel) {} label: { L10n.Common.cancel }
            Button(role: .destructive) {
                Task { await viewModel.reReadPDF() }
            } label: {
                Text("reader.pdf.reread.confirm.action", bundle: .module)
            }
        } message: {
            Text("reader.pdf.reread.confirm.body", bundle: .module)
        }
        .alert(
            Text("reader.pdf.reread.failed.title", bundle: .module),
            isPresented: Binding(
                get: { viewModel.reReadError != nil },
                set: { if !$0 { viewModel.reReadError = nil } },
            ),
        ) {
            Button {} label: { L10n.Common.ok }
        } message: {
            Text(viewModel.reReadError ?? "")
        }
    }
}
