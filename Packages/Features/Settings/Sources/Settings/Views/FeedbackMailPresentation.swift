import SwiftUI
import UtilityUI

/// Presents the feedback-mail composer plus the alerts that report its outcome, and owns the state both need.
///
/// **Attach this to the screen-level container (the Settings `Form`), never to a `Section` or a row inside one.** A
/// presentation modifier written after a `Section` is applied to each of that section's rows, so one `isPresented`
/// binding ends up driving several presentations at once; SwiftUI resolves that conflict by tearing the sheet down
/// the instant it appears, which is exactly how the mail composer became unusable (it opened and closed again in the
/// same frame). Keeping the modifier on a single, always-present container keeps one presentation per binding.
private struct FeedbackMailPresentation: ViewModifier {
    @Binding var isPresented: Bool

    @State private var result: FeedbackMailComposeResult?
    @State private var isSavedAlertPresented = false
    @State private var isFailedAlertPresented = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                FeedbackMailView(result: $result)
            }
            .alert(
                Text("settings.feedback.saved.title", bundle: .module),
                isPresented: $isSavedAlertPresented,
            ) {
                Button(role: .cancel) {} label: { L10n.Common.ok }
            }
            .alert(
                Text("settings.feedback.failed.title", bundle: .module),
                isPresented: $isFailedAlertPresented,
            ) {
                Button(role: .cancel) {} label: { L10n.Common.ok }
            }
            .onChange(of: result) { _, newValue in
                switch newValue {
                case .saved:
                    isSavedAlertPresented = true
                case .failed:
                    isFailedAlertPresented = true
                case .cancelled, .sent, nil:
                    break
                }
            }
    }
}

extension View {
    /// Hosts the feedback-mail flow driven by `isPresented`. See `FeedbackMailPresentation` for where it may go.
    func feedbackMailPresentation(isPresented: Binding<Bool>) -> some View {
        modifier(FeedbackMailPresentation(isPresented: isPresented))
    }
}
