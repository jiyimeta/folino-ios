import SwiftUI
import UtilityUI

extension View {
    /// A confirmation that points at the control that raised it: a message and one destructive button, in a popover
    /// anchored to this view.
    ///
    /// A popover rather than `confirmationDialog`, and attached to the button rather than to the strip's root,
    /// because both of those decide where it appears. On a phone `confirmationDialog` is an action sheet that rises
    /// from the bottom of the screen — correct iOS, but it leaves a control at the top of the display asking its
    /// question at the opposite end of the phone. `presentationCompactAdaptation(.popover)` is what stops the
    /// popover from being adapted back into that sheet in a compact size class.
    ///
    /// The cost, accepted knowingly: a popover is anchored to a view, so it goes down with that view. The strip's
    /// two confirmations used to live on `EditorTopBarView`'s stable root precisely so a `ViewThatFits` refold or a
    /// cutout-tier toggle could not tear them down mid-question. Anchoring is worth more than surviving a rotation
    /// taken while the question is on screen — and the controls that raise these are the two that never fold.
    ///
    /// One button, no cancel: dismissing a popover is tapping outside it, which every iOS user already knows, and a
    /// cancel button would make the destructive one look like a choice between equals.
    ///
    /// The button is glass with a red label, not a red fill and not a stroked outline. That is measured, not
    /// guessed: sampling Photos' own button shows its interior is not uniform — a blue patch (R 194 / B 212) sits
    /// exactly where blue content lies behind it, while the popover's own background at the same x is neutral to
    /// within one level. Only a surface sampling its backdrop does that.
    func destructiveConfirmationPopover(
        isPresented: Binding<Bool>,
        message: String,
        actionTitle: Text,
        action: @escaping () -> Void,
    ) -> some View {
        popover(isPresented: isPresented) {
            DestructiveConfirmationContent(message: message, actionTitle: actionTitle) {
                isPresented.wrappedValue = false
                action()
            }
            // Stops the popover being adapted back into a bottom sheet in a compact size class — which is the whole
            // reason this exists rather than `confirmationDialog`.
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// The popover's body, as its own view so it can be seen in a `#Preview` — a popover cannot be rendered in one, and
/// the thing worth checking (does the message wrap, or get cut off?) is exactly what a preview can answer.
private struct DestructiveConfirmationContent: View {
    let message: String
    let actionTitle: Text
    let action: () -> Void

    /// Sizes taken off a Photos screenshot at this raster (1206x2622, iPhone 16 Pro): its popover's content is 273pt
    /// wide, its button a 226x57pt capsule, i.e. 23.5pt in from each side.
    private enum Metrics {
        static let width: CGFloat = 273
        static let horizontalPadding: CGFloat = 24
        static let buttonHeight: CGFloat = 57
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(message)
                .font(.body)
                // Leading, not centred: Photos' reads as a paragraph, and a centred one of three or four wrapped
                // lines turns into a ragged diamond.
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Without this the popover proposes a height the text is then truncated to. `horizontal: false`
                // keeps the width the frame below sets, so the message wraps and grows downwards instead.
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive, action: action) {
                actionTitle
                    .font(.body)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: Metrics.buttonHeight)
                    .interactiveGlassCompat(in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, 20)
        .frame(width: Metrics.width)
        // The popover sizes to what its content asks for; the stack has to ask for its full height or the system
        // settles on its own and clips.
        .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
// The two real messages, at their real width. The revert one is the long case — its caveats are what would be cut
// off if the sizing were wrong.
#Preview("Confirmation content") {
    VStack(spacing: 24) {
        DestructiveConfirmationContent(
            message: String(localized: "editor.discard.confirm.message", bundle: .module),
            actionTitle: Text("editor.discard.confirm.action", bundle: .module),
            action: {},
        )
        .background(.background, in: .rect(cornerRadius: 14))

        DestructiveConfirmationContent(
            message: [
                String(localized: "editor.revert.confirm.body", bundle: .module),
                String(localized: "editor.revert.confirm.inkMayShift", bundle: .module),
                String(localized: "editor.revert.confirm.mayNotBeImport", bundle: .module),
            ].joined(separator: "\n\n"),
            actionTitle: Text("editor.revert.confirm.action", bundle: .module),
            action: {},
        )
        .background(.background, in: .rect(cornerRadius: 14))
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(white: 0.9))
}
#endif
