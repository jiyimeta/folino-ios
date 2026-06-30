import SwiftUI
import UtilityUI

/// Body copy for the PDF-playback caveat, chosen from the current playback state: the best-effort caveat while a PDF
/// is playable (or being parsed), or the "couldn't prepare" message when the parse failed.
private func pdfPlaybackNoticeBodyKey(for state: PDFPlaybackState) -> String.LocalizationValue {
    if case .unavailable = state { return "reader.pdf.playback.unavailable.body" }
    return "reader.pdf.playback.notice.body"
}

/// One-time, dismissible banner shown the first time an opened PDF becomes playable, explaining that OMR is
/// best-effort. Dismissing it persists `ReaderGlobalSettingsKey.pdfPlaybackNoticeDismissed`; the same caveat stays
/// reachable any time by tapping the PDF badge (`PDFPlaybackNoticeSheet`).
struct PDFPlaybackNoticeBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "music.note.list")
                Text("reader.pdf.playback.notice.title", bundle: .module)
                    .font(.subheadline.weight(.semibold))
            }
            Text("reader.pdf.playback.notice.body", bundle: .module)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Text("reader.pdf.playback.notice.dismiss", bundle: .module)
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
        .padding(.horizontal)
    }
}

/// On-demand caveat shown when the user taps the PDF badge. Same copy as the one-time banner (state-dependent), with
/// no "don't show again" — it's always available.
struct PDFPlaybackNoticeSheet: View {
    let state: PDFPlaybackState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("reader.pdf.playback.notice.title", bundle: .module)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(String(localized: pdfPlaybackNoticeBodyKey(for: state), bundle: .module))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { dismiss() } label: {
                L10n.Common.ok.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
