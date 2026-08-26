import Domain
import SwiftUI

/// The instrument catalog as a pickable list, grouped by family.
///
/// Deliberately just the list: no navigation title, no toolbar, no sheet of its own. Two screens present it — the
/// new-score wizard's "add a part" step and the editor's instrumentation sheet — and each owns a different container
/// and a different dismissal, so anything this view decided for them would have to be undone on one side.
///
/// It is also stateless. Nothing here knows which instruments the caller has already taken, and duplicate numbering
/// ("Violin 1 / Violin 2") is the caller's job — the catalog offers instruments, a part list names parts.
public struct InstrumentCatalogPicker: View {
    private let onPick: (ScoreInstrument) -> Void

    public init(onPick: @escaping (ScoreInstrument) -> Void) {
        self.onPick = onPick
    }

    public var body: some View {
        List {
            // `Family.allCases` rather than a grouping of `all`: the enum's declaration order IS the order the
            // sections are offered in (see `ScoreInstrument.Family`), so walking the cases keeps the two in step.
            ForEach(ScoreInstrument.Family.allCases, id: \.self) { family in
                Section {
                    ForEach(family.instruments) { instrument in
                        InstrumentRow(instrument: instrument) { onPick(instrument) }
                    }
                } header: {
                    Text(localizedInstrumentFamilyName(family))
                }
            }
        }
    }
}

/// One catalog row. Split out of the picker's body so the label keeps its own foreground style: a `Button` inside a
/// `List` tints its label with the accent color, which would read as a link rather than as a list of instruments.
private struct InstrumentRow: View {
    let instrument: ScoreInstrument
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            Text(localizedInstrumentName(instrument))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The label, not the row, is what the button hit-tests, so it has to span the row itself —
                // otherwise the tappable area stops at the end of a short name like "Oboe".
                .contentShape(.rect)
        }
    }
}

#Preview {
    NavigationStack {
        InstrumentCatalogPicker { _ in }
    }
}
