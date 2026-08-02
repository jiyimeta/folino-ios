import Domain
import SwiftUI
import UtilityUI

/// Title / body for the PDF-source notice, chosen from how far the conversion got.
private func pdfSourceNoticeTitleKey(for state: PDFOriginState) -> String.LocalizationValue {
    state == .converted ? "reader.pdf.source.notice.title" : "reader.pdf.source.unavailable.title"
}

/// Internal (not private) so the PDF badge's menu can head itself with the same words the notice uses — the badge is
/// where that explanation stays reachable once the dialog has been dismissed for good.
func pdfSourceNoticeBodyKey(for state: PDFOriginState) -> String.LocalizationValue {
    state == .converted ? "reader.pdf.source.notice.body" : "reader.pdf.source.unavailable.body"
}

extension View {
    /// Explains what folino did with the PDF: that it read it into notation, that the result is now an ordinary
    /// editable score, that a misread note can be fixed on the spot with the note-input button, and that the original
    /// pages are one tap away. For a PDF folino couldn't read, it says so and points at the re-read action.
    ///
    /// Two buttons: a color-emphasized **OK** that closes it for now, and a plain **Don't show again** that suppresses
    /// the automatic presentation thereafter. The explanation stays reachable any time via the PDF badge.
    func pdfSourceNoticeAlert(
        originState: PDFOriginState,
        isPresented: Binding<Bool>,
        onDontShowAgain: @escaping () -> Void,
    ) -> some View {
        alert(
            Text(String(localized: pdfSourceNoticeTitleKey(for: originState), bundle: .module)),
            isPresented: isPresented,
        ) {
            // iOS 26's `.confirm` role renders as the prominent tinted (colored) action — the emphasized OK. It only
            // closes the dialog for now; there's no permanent effect. On iOS 18 the default-action keyboard shortcut
            // is what marks an alert button as the emphasized (bold) one.
            if #available(iOS 26, *) {
                Button(role: .confirm) {} label: { L10n.Common.ok }
            } else {
                Button {} label: { L10n.Common.ok }
                    .keyboardShortcut(.defaultAction)
            }
            Button { onDontShowAgain() } label: {
                Text("reader.pdf.source.notice.dismiss", bundle: .module)
            }
        } message: {
            Text(String(localized: pdfSourceNoticeBodyKey(for: originState), bundle: .module))
        }
    }
}
