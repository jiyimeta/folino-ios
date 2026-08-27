import SwiftUI

/// A time signature as a control: the meters people actually pick as a row of chips, plus two steppers for
/// everything else. The chips are a shortcut, not the vocabulary — anything the steppers can reach is offerable,
/// so 5/8 and 11/16 are as available as 4/4.
///
/// Deliberately just the control — three sibling rows, no section, no navigation, no dismissal (the
/// `InstrumentCatalogPicker` contract). A `List` / `Form` flattens a view's body into its own content, so
/// dropping this into one lays the three out as rows beside the caller's, not as one row containing them.
public struct TimeSignaturePicker: View {
    /// The chips, in the order they are offered. The common meters first, then the ones worth a shortcut.
    public static let presets: [(Int, Int)] = [
        (4, 4), (3, 4), (2, 4), (6, 8), (12, 8), (2, 2), (5, 4), (7, 8), (9, 8), (3, 8),
    ]

    /// The note values a denominator can take. The stepper walks this set rather than ±1: 5/3 is not a time
    /// signature, and halving or doubling the beat unit is what a musician means by "the next one".
    static let denominators = [1, 2, 4, 8, 16, 32]
    /// Beats per bar. Two digits is past anything engraved; the cap only keeps a held stepper from running away.
    static let numerators = 1 ... 63

    @Binding private var numerator: Int
    @Binding private var denominator: Int

    public init(numerator: Binding<Int>, denominator: Binding<Int>) {
        _numerator = numerator
        _denominator = denominator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent {
                Text(verbatim: "\(numerator)/\(denominator)")
                    .monospacedDigit()
            } label: {
                Text("scoreUI.timeSignature.label", bundle: .module)
            }
            presetChips
        }
        Stepper(value: $numerator, in: Self.numerators) {
            LabeledContent {
                Text(numerator, format: .number)
            } label: {
                Text("scoreUI.timeSignature.beats", bundle: .module)
            }
        }
        Stepper(onIncrement: incrementDenominator, onDecrement: decrementDenominator) {
            LabeledContent {
                Text(denominator, format: .number)
            } label: {
                Text("scoreUI.timeSignature.beatUnit", bundle: .module)
            }
        }
    }

    /// Horizontally scrollable rather than wrapped: ten chips do not fit one iPhone line, and a wrapping row
    /// changes its own height as the enclosing width changes, which a form row reads badly.
    private var presetChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                // `(Int, Int)` is not `Hashable`, so a chip's identity is its position in the table.
                ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, preset in
                    chip(preset)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ preset: (Int, Int)) -> some View {
        let isSelected = numerator == preset.0 && denominator == preset.1
        return Button {
            numerator = preset.0
            denominator = preset.1
        } label: {
            Text(verbatim: "\(preset.0)/\(preset.1)")
                .font(.subheadline)
                .monospacedDigit()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill), in: .capsule)
        }
        // Without `.plain`, a `Button` inside a `List` tints its whole label with the accent color — which erases
        // the selected/unselected distinction the chips are drawn to carry.
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// `nil` at the ends of `denominators`, which is what greys the stepper's half out rather than letting it
    /// press against a value that cannot move.
    private var incrementDenominator: (() -> Void)? {
        denominator >= (Self.denominators.last ?? 0) ? nil : { stepDenominator(by: 1) }
    }

    private var decrementDenominator: (() -> Void)? {
        denominator <= (Self.denominators.first ?? 0) ? nil : { stepDenominator(by: -1) }
    }

    /// Moves the denominator `offset` places through `denominators`. A value outside the set (nothing in folino
    /// produces one, but a caller could) snaps to the nearest allowed note value first.
    private func stepDenominator(by offset: Int) {
        let current = Self.denominators.firstIndex(of: denominator)
            ?? Self.denominators.firstIndex { $0 >= denominator }
            ?? Self.denominators.indices.last
            ?? 0
        let next = min(max(current + offset, 0), Self.denominators.count - 1)
        denominator = Self.denominators[next]
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
