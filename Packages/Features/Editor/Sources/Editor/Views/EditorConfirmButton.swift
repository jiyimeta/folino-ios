import SwiftUI
import UtilityUI

/// The confirming control on the editing strip's sheets: a round, prominently tinted button holding a checkmark.
///
/// A glyph rather than a verb because these sheets sit at a `.medium` detent over the score the user is still
/// looking at — small, half the screen, the page live behind them. At that size a tinted mark reads as "commit" in
/// one glance, and it reads the same in every language folino ships without the button growing to fit. Nothing is
/// lost to VoiceOver: `label` is the verb the button used to spell out.
///
/// The tint is the BUTTON's, through the prominent style — not a filled circle drawn inside a plain one. Painting
/// an accent disc behind the glyph leaves the toolbar's own glass capsule around it, so the colour reads as a badge
/// sitting in a button rather than as the button itself.
struct EditorConfirmButton: View {
    let label: Text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .semibold))
        }
        // `.glassProminent` on iOS 26, `.borderedProminent` at the iOS 18 floor — the style tints the whole
        // control, and `.circle` is what makes that whole control a disc.
        .glassProminentButtonStyleCompat()
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        Form {
            Text(verbatim: "Sheet content")
        }
        .navigationTitle(Text(verbatim: "Time Signature"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                EditorConfirmButton(label: Text(verbatim: "Apply")) {}
            }
        }
    }
}
#endif
