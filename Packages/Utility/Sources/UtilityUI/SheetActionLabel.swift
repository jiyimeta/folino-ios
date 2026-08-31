import SwiftUI

/// A sheet's confirm or close action, drawn the way iOS 26 draws sheet chrome: a glyph, not a word.
///
/// iOS 26 replaced the navigation bar's trailing "Done" with a circular checkmark and its leading "Close" with an
/// ✕. Dropping the word costs nothing here because every sheet that wears this pair means exactly one thing by it —
/// commit the draft on screen, or throw it away — so there is no distinction for the glyph to lose. A toolbar
/// action that means anything else keeps its label; a checkmark reads as "confirm" and would misdescribe it.
///
/// The word is still passed in and kept as the label's title, hidden with `.labelStyle(.iconOnly)`: an icon-only
/// control with no text has no accessible name either, and VoiceOver has to be able to say which button this is.
public struct SheetActionLabel: View {
    public enum Kind: Sendable {
        /// Commit what the sheet is holding, and close.
        case confirm
        /// Close without committing.
        case close

        var systemImage: String {
            switch self {
            case .confirm: "checkmark"
            case .close: "xmark"
            }
        }
    }

    private let kind: Kind
    private let title: Text

    public init(_ kind: Kind, title: Text) {
        self.kind = kind
        self.title = title
    }

    public var body: some View {
        Label { title } icon: { Image(systemName: kind.systemImage) }
            .labelStyle(.iconOnly)
    }
}

/// The confirming control on a sheet's navigation bar: a round, prominently tinted button holding a checkmark.
///
/// The tint is the BUTTON's, through the prominent style — not a filled circle drawn inside a plain one. Painting an
/// accent disc behind the glyph leaves the toolbar's own glass capsule around it, so the colour reads as a badge
/// sitting in a button rather than as the button itself.
///
/// A button rather than a bare label because the styling is the shared part: every sheet that commits a draft should
/// look identical doing it, and a caller that only borrowed the glyph would have to remember the style too. The
/// closing ✕ has no such styling — iOS 26 draws it plain — so it stays a `SheetActionLabel` inside an ordinary
/// `Button`.
public struct SheetConfirmButton: View {
    private let title: Text
    private let action: () -> Void

    public init(title: Text, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            SheetActionLabel(.confirm, title: title)
                .font(.system(size: 15, weight: .semibold))
        }
        // `.glassProminent` on iOS 26, `.borderedProminent` at the iOS 18 floor — the style tints the whole control,
        // and `.circle` is what makes that whole control a disc.
        .glassProminentButtonStyleCompat()
        .buttonBorderShape(.circle)
    }
}

#if DEBUG
#Preview("sheet actions") {
    NavigationStack {
        Text(verbatim: "Sheet body")
            .inlineNavigationTitleCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {} label: { SheetActionLabel(.close, title: Text(verbatim: "Cancel")) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton(title: Text(verbatim: "Save")) {}
                }
            }
    }
}
#endif
