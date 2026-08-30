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

#if DEBUG
#Preview("sheet actions") {
    NavigationStack {
        Text(verbatim: "Sheet body")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {} label: { SheetActionLabel(.close, title: Text(verbatim: "Cancel")) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {} label: { SheetActionLabel(.confirm, title: Text(verbatim: "Save")) }
                        .buttonStyle(.borderedProminent)
                }
            }
    }
}
#endif
