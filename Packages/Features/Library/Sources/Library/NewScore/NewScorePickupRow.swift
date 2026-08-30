import Domain
import ScoreUI
import SwiftUI

/// The opening bar's own length, picked the way the time signature above it is: `弱起  [n ⌄] / [d ⌄]`, with a
/// "none" entry at the top of the beat-count menu for a score that just starts on the downbeat.
///
/// The menus are rebuilt from the current meter, so the row cannot offer a pickup longer than the bar it opens,
/// and `NewScoreForm.pickup` answers `nil` for a stored value the current meter does not admit — the selection
/// can never point at an entry that is not there.
@MainActor
struct NewScorePickupRow: View {
    @Binding var pickup: Fraction?
    let timeNumerator: Int
    let timeDenominator: Int

    /// The note value the pickup is currently *spelled* over, which is not something the stored value can carry:
    /// `Fraction` reduces on construction, so a pickup picked as 2/8 comes back as 1/4. Without this the beat-count
    /// menu would answer a tap on "2" by showing "1", and the note-value menu would jump from 8 to 4 underneath it.
    /// The row keeps the spelling and re-writes the stored value over it.
    @State private var spelling: Int?

    var body: some View {
        FractionMenuRow(
            Text("library.newScore.field.pickup", bundle: .module),
            numerator: numeratorBinding,
            denominator: denominatorBinding,
            numeratorChoices: NewScoreForm.pickupNumerators(
                over: denominator, numerator: timeNumerator, denominator: timeDenominator,
            ),
            denominatorChoices: denominatorChoices,
            noneLabel: Text("library.newScore.field.pickup.none", bundle: .module),
        )
        // A spelling the user chose belongs to the meter they chose it under. Once the beat unit moves, the row
        // goes back to following the meter — otherwise a pickup picked in eighths would keep offering eighths
        // after a switch to 3/16, which is not the unit that meter counts in.
        .onChange(of: timeDenominator) { _, _ in spelling = nil }
    }

    private var denominatorChoices: [Int] {
        NewScoreForm.pickupDenominators(numerator: timeNumerator, denominator: timeDenominator)
    }

    /// The note value the menus run on, in order of who has the better claim to it:
    ///
    /// 1. the spelling the user picked, while the meter still admits it — and only until the meter's beat unit
    ///    moves, which clears it (see `body`);
    /// 2. the one a stored pickup reduced to, so 3/8 keeps reading as 3/8;
    /// 3. **the meter's own denominator** — a pickup in 3/4 is counted in quarters unless something says otherwise,
    ///    and following the meter is what makes the row read as a companion to the one above it;
    /// 4. the finest the meter offers, for a meter too short to spell a pickup in its own unit (1/4 has no
    ///    quarter-note pickup, only an eighth).
    private var denominator: Int {
        let choices = denominatorChoices
        if let spelling, choices.contains(spelling) {
            return spelling
        }
        if let pickup, choices.contains(pickup.denominator) {
            return pickup.denominator
        }
        if choices.contains(timeDenominator) {
            return timeDenominator
        }
        return choices.last ?? max(8, timeDenominator)
    }

    /// The stored pickup re-spelled over `denominator`, or `nil` when there is none — or when the spelling cannot
    /// express it (the note value moved under a stored value it does not divide), which reads as "none" until the
    /// menus agree again, exactly as an unfitting pickup already does.
    private var numeratorBinding: Binding<Int?> {
        Binding(
            get: {
                guard let pickup, denominator % pickup.denominator == 0 else { return nil }
                return pickup.numerator * (denominator / pickup.denominator)
            },
            set: { newValue in
                spelling = denominator
                guard let newValue else {
                    pickup = nil
                    return
                }
                pickup = Fraction(numerator: newValue, denominator: denominator)
            },
        )
    }

    /// Changing the note value keeps the pickup's *length* where the new value can express it, so switching 4/8 to
    /// quarters gives 2/4 rather than dropping the pickup. Where it cannot, the length rounds down to the longest
    /// the new value offers — never up, which would push the pickup past the bar.
    private var denominatorBinding: Binding<Int> {
        Binding(
            get: { denominator },
            set: { newValue in
                spelling = newValue
                guard let current = pickup else { return }
                let counts = NewScoreForm.pickupNumerators(
                    over: newValue, numerator: timeNumerator, denominator: timeDenominator,
                )
                // The same length over the new note value, rounded down to what that value can write.
                let scaled = current.numerator * newValue / current.denominator
                guard let count = counts.last(where: { $0 <= scaled }) ?? counts.first else {
                    pickup = nil
                    return
                }
                pickup = Fraction(numerator: count, denominator: newValue)
            },
        )
    }
}

#if DEBUG
#Preview {
    @Previewable @State var pickup: Fraction? = Fraction(numerator: 3, denominator: 8)
    Form {
        NewScorePickupRow(pickup: $pickup, timeNumerator: 4, timeDenominator: 4)
    }
}
#endif
