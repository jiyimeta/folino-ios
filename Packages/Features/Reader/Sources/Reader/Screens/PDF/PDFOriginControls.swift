import Domain
import SwiftUI
import UtilityUI

/// What an item that came from a PDF lets the user do about it: look at the original pages instead of the notation
/// folino parsed out of them, and parse that PDF again.
///
/// A value rather than a view-model reference so the inspector — which is handed plain models, not the reader session —
/// can carry these without learning about `ReaderViewModel`.
struct PDFOriginControls {
    /// Whether the original PDF pages are what's on screen. Setting it to `false` shows the parsed notation.
    var showsOriginalPDF: Bool
    /// `nil` when there is no notation to switch to: folino couldn't parse this PDF, so the original is all there is.
    var setShowsOriginalPDF: ((Bool) -> Void)?
    /// Runs the re-parse, or raises the confirmation first when there is work to lose. `nil` hides the action.
    var reParse: (() -> Void)?
}

/// The PDF section of the display inspector: the original / parsed switch, and the re-parse. Collapsible and
/// remembered across opens, like the inspector's other sections — it only concerns items that came from a PDF, so
/// someone who has read all this once can fold it away.
struct PDFOriginSection: View {
    let controls: PDFOriginControls

    @AppStorage("reader.inspector.visual.pdf.expanded") private var isExpanded = true

    var body: some View {
        CollapsibleSection(isExpanded: $isExpanded) {
            if let setShowsOriginalPDF = controls.setShowsOriginalPDF {
                // Described in the row rather than in a section footer, matching how the app's own settings screen
                // explains a toggle whose consequence isn't obvious from its title alone.
                Toggle(isOn: Binding(
                    get: { controls.showsOriginalPDF },
                    set: { setShowsOriginalPDF($0) },
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("reader.displaySource.showOriginal", bundle: .module)
                        Text("reader.displaySource.showOriginal.description", bundle: .module)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let reParse = controls.reParse {
                // Tinted text, no leading glyph: in an iOS form the colour of the label IS what says the row acts,
                // while a leading icon says what a row is ABOUT — every setting row above has one. Giving this row an
                // icon made it read as one more setting. The verb phrase carries the rest.
                Button {
                    reParse()
                } label: {
                    // The accent colour is stated rather than left to the button style. `.automatic` inside this list
                    // renders the label in the ordinary label colour, which is precisely the "reads as one more
                    // setting" problem. `.borderless` would tint it, but shrinks the hit area to the text — the row
                    // should stay tappable edge to edge, as every action row in iOS is.
                    Text("reader.pdf.reread.action", bundle: .module)
                        .foregroundStyle(Color.accentColor)
                }
            }
        } header: {
            // Verbatim: the format's name is the same in every locale, as it is on the badge.
            Text(verbatim: "PDF")
        }
    }
}
