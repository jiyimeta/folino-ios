import SwiftUI

/// A time signature as a control: one row, the beats and the beat unit each a menu.
///
/// Every meter is reached the same way. An earlier version put the common meters on a row of preset chips over
/// two steppers, which made 4/4 one tap and 11/16 a walk; two menus cost the same for either, and the beat unit
/// is a menu over `FractionMenuRow.noteValues` rather than a free number, since 5/3 is not a time signature.
///
/// Deliberately just the control — one row, no section, no navigation, no dismissal (the
/// `InstrumentCatalogPicker` contract). A `List` / `Form` lays it out as one of its own rows.
public struct TimeSignaturePicker: View {
    /// Beats per bar. Two digits is past anything engraved; the cap is what keeps the menu finite.
    /// `nonisolated` for the same reason as `FractionMenuRow.noteValues` — vocabulary, not state.
    nonisolated static let numerators = Array(1 ... 63)

    @Binding private var numerator: Int
    @Binding private var denominator: Int

    public init(numerator: Binding<Int>, denominator: Binding<Int>) {
        _numerator = numerator
        _denominator = denominator
    }

    public var body: some View {
        FractionMenuRow(
            Text("scoreUI.timeSignature.label", bundle: .module),
            numerator: $numerator,
            denominator: $denominator,
            numeratorChoices: Self.numerators,
        )
    }
}

#Preview {
    @Previewable @State var numerator = 4
    @Previewable @State var denominator = 4
    Form {
        Section {
            TimeSignaturePicker(numerator: $numerator, denominator: $denominator)
        }
    }
}
