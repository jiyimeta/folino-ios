import SwiftUI
import UtilityUI

/// Body copy for the PDF-playback caveat, chosen from the current playback state: the best-effort caveat while a PDF
/// is playable (or being parsed), or the "couldn't read" message when the parse failed.
private func pdfPlaybackNoticeBodyKey(for state: PDFPlaybackState) -> String.LocalizationValue {
    if case .unavailable = state { return "reader.pdf.playback.unavailable.body" }
    return "reader.pdf.playback.notice.body"
}

extension View {
    /// Presents the PDF-playback caveat as an OK dialog explaining that the original PDF is read (parsed) to play it,
    /// the result isn't always accurate, and it works best with MuseScore-/folino-exported PDFs.
    ///
    /// Two buttons: a color-emphasized **OK** (`.confirm` role) that just closes it for now, and a plain **Don't show
    /// again** (`onDontShowAgain`) that suppresses the automatic presentation thereafter. The caveat stays reachable
    /// any time via the PDF badge.
    func pdfPlaybackNoticeAlert(
        state: PDFPlaybackState,
        isPresented: Binding<Bool>,
        onDontShowAgain: @escaping () -> Void,
    ) -> some View {
        alert(
            Text("reader.pdf.playback.notice.title", bundle: .module),
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
                Text("reader.pdf.playback.notice.dismiss", bundle: .module)
            }
        } message: {
            Text(String(localized: pdfPlaybackNoticeBodyKey(for: state), bundle: .module))
        }
    }
}
