import Domain
import ScoreUI
import SwiftUI

/// The meter in force at the target bar, editable. The counterpart to `EditorKeySignatureSheet` — same scaffold, the
/// meter's two menus instead of the circle of fifths.
@MainActor
struct EditorTimeSignatureSheet: View {
    let viewModel: EditorViewModel
    /// The picked meter, seeded once from what is in force at the target bar; 4/4 without a target, which the
    /// disabled menu row keeps unreachable. Two `@State`s rather than one pair, because `TimeSignaturePicker` binds
    /// the halves separately (see `FractionMenuRow`'s note on the transient a caller is briefly asked about).
    @State private var numerator: Int
    @State private var denominator: Int

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
        let current = viewModel.targetTimeSignature ?? EditorTimeSignatureValue(numerator: 4, denominator: 4)
        _numerator = State(initialValue: current.numerator)
        _denominator = State(initialValue: current.denominator)
    }

    var body: some View {
        EditorSignatureSheet(
            viewModel: viewModel,
            title: "editor.signature.time.title",
            currentValue: currentValue,
            hasExplicitChange: viewModel.targetHasExplicitTimeChange,
            removalMessage: "editor.signature.remove.message.time",
            apply: { viewModel.setTimeSignature(numerator: numerator, denominator: denominator) },
            remove: { viewModel.removeTimeSignatureChange() },
        ) {
            TimeSignaturePicker(numerator: $numerator, denominator: $denominator)
        }
    }

    /// "n/d" — the way a meter is written on a page, in every language folino ships, so it is verbatim rather than a
    /// catalog string.
    private var currentValue: String {
        let current = viewModel.targetTimeSignature
            ?? EditorTimeSignatureValue(numerator: numerator, denominator: denominator)
        return "\(current.numerator)/\(current.denominator)"
    }
}

#if DEBUG
#Preview("Time — mid-piece change") {
    EditorSignatureSheetPreviews.timeSheet(targetingBarWithChange: true)
}

#Preview("Time — inherited") {
    EditorSignatureSheetPreviews.timeSheet(targetingBarWithChange: false)
}

#Preview("Time — refused") {
    EditorSignatureSheetPreviews.timeSheetRefusing()
}
#endif
