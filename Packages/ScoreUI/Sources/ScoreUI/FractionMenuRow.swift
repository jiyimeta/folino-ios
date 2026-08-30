import SwiftUI

/// A fraction picked as two menus — `label   [n ⌄] / [d ⌄]` — on one row.
///
/// The shape every "a number over a number" in folino is picked with: the time signature, and the creation
/// wizard's pickup. One row rather than two look-alikes is the point — they are the same question asked about two
/// things, and the wizard puts them one under the other.
///
/// Deliberately just the row, like the pickers beside it (the `InstrumentCatalogPicker` contract): no section, no
/// navigation, no dismissal. A `Form` lays it out as one of its own rows.
///
/// The two halves are written one after the other, never as a pair — they are two bindings, and this view has no
/// way to set them together. A caller deriving anything from the fraction is therefore briefly asked about a
/// transient (new numerator, old denominator); the creation wizard's pickup is validated on read rather than
/// cleared on write for exactly that reason.
public struct FractionMenuRow: View {
    /// The note values a denominator can take. Halving or doubling the beat unit is what a musician means by
    /// "the next one" — 5/3 is not a time signature and 1/3 is not a pickup, so the menu offers this set rather
    /// than a range.
    ///
    /// `nonisolated` because a `View` is `@MainActor`, and this table is vocabulary rather than state: the
    /// creation wizard derives its pickup menus from it off the main actor.
    public nonisolated static let noteValues = [1, 2, 4, 8, 16, 32]

    private let label: Text
    private let noneLabel: Text?
    private let numeratorChoices: [Int]
    private let denominatorChoices: [Int]
    @Binding private var numerator: Int?
    @Binding private var denominator: Int

    /// A fraction that is always present — a time signature.
    public init(
        _ label: Text,
        numerator: Binding<Int>,
        denominator: Binding<Int>,
        numeratorChoices: [Int],
        denominatorChoices: [Int] = FractionMenuRow.noteValues,
    ) {
        self.label = label
        noneLabel = nil
        self.numeratorChoices = numeratorChoices
        self.denominatorChoices = denominatorChoices
        _numerator = Binding(
            get: { numerator.wrappedValue },
            set: { newValue in
                // Unreachable without a `noneLabel`: with no "none" entry, the menu has no nil to offer.
                if let newValue {
                    numerator.wrappedValue = newValue
                }
            },
        )
        _denominator = denominator
    }

    /// A fraction that can be absent, `noneLabel` naming the absence — the wizard's pickup.
    ///
    /// Both menus stay on screen while the fraction is absent, rather than the denominator appearing only once a
    /// numerator is picked: the row is meant to read as the same control as the time signature above it, and one
    /// that grows a second menu halfway through reads as a different one.
    public init(
        _ label: Text,
        numerator: Binding<Int?>,
        denominator: Binding<Int>,
        numeratorChoices: [Int],
        denominatorChoices: [Int] = FractionMenuRow.noteValues,
        noneLabel: Text,
    ) {
        self.label = label
        self.noneLabel = noneLabel
        self.numeratorChoices = numeratorChoices
        self.denominatorChoices = denominatorChoices
        _numerator = numerator
        _denominator = denominator
    }

    public var body: some View {
        LabeledContent {
            // Zero spacing plus a leading pad on the slash, rather than an even `HStack` spacing: a menu picker
            // carries its own leading padding, so even spacing lands twice on the slash's right and leaves it
            // jammed against the first number.
            HStack(spacing: 0) {
                numeratorMenu
                // Verbatim: a fraction is written the same way in every language folino ships.
                Text(verbatim: "/")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                denominatorMenu
            }
        } label: {
            label
        }
    }

    /// `.labelsHidden()` rather than no label: the row's own label says *which* fraction this is, and the menu's
    /// says which half of it — together they are what VoiceOver reads, and only the second is redundant on screen.
    private var numeratorMenu: some View {
        Picker(selection: $numerator) {
            if let noneLabel {
                noneLabel.tag(Int?.none)
            }
            ForEach(numeratorChoices, id: \.self) { value in
                Text(value, format: .number).tag(Int?.some(value))
            }
        } label: {
            Text("scoreUI.fraction.numerator", bundle: .module)
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private var denominatorMenu: some View {
        Picker(selection: $denominator) {
            ForEach(denominatorChoices, id: \.self) { value in
                Text(value, format: .number).tag(value)
            }
        } label: {
            Text("scoreUI.fraction.denominator", bundle: .module)
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }
}

#Preview {
    @Previewable @State var numerator = 4
    @Previewable @State var denominator = 4
    @Previewable @State var pickupNumerator: Int?
    @Previewable @State var pickupDenominator = 8
    Form {
        FractionMenuRow(
            Text(verbatim: "Time Signature"),
            numerator: $numerator,
            denominator: $denominator,
            numeratorChoices: Array(1 ... 16),
        )
        FractionMenuRow(
            Text(verbatim: "Pickup"),
            numerator: $pickupNumerator,
            denominator: $pickupDenominator,
            numeratorChoices: Array(1 ... 7),
            denominatorChoices: [2, 4, 8],
            noneLabel: Text(verbatim: "None"),
        )
    }
}
