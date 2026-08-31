import SheetMusicCore
import SwiftUI
import UtilityUI

// PARITY(android): M3 signature editing — Android needs the sheet UI; ssm logic is shared

/// The shape both signature sheets have: which bar is being changed and what it currently says, the picker, the one
/// line explaining how far the change reaches, and — where the bar declares a change of its own — the destructive row
/// that takes it back out.
///
/// One scaffold rather than two nearly-identical sheets, because everything except the picker and four strings is
/// the same: the apply/dismiss/refuse dance in particular is easy to get subtly wrong twice.
///
/// **Apply does not always dismiss.** `apply` reports whether anything landed, and a `false` keeps the sheet up so
/// the alert has somewhere to appear — except for the quiet no-op (picking the value the bar is already in), which
/// the view model reports as `false` with NO refusal recorded. That case simply closes: the user asked for a state
/// the score is already in, and they got it.
@MainActor
struct EditorSignatureSheet<Picker: View>: View {
    let viewModel: EditorViewModel
    /// Navigation title — "Key Signature" / "Time Signature".
    let title: LocalizedStringKey
    /// What the target bar says today, already formatted ("C / Am", "3/4"). Engraving vocabulary, so not localized.
    let currentValue: String
    /// Whether the target bar declares a signature of THIS kind itself, which is what the Remove section acts on.
    let hasExplicitChange: Bool
    /// The one line under the Remove row saying what dropping the change does to the bars after it.
    let removalMessage: LocalizedStringKey
    /// Writes the picked value. `true` when the score changed.
    let apply: () -> Bool
    /// Drops the target bar's own change. `true` when the score changed.
    let remove: () -> Bool
    @ViewBuilder let picker: () -> Picker

    @Environment(\.dismiss) private var dismiss
    /// Whether the destructive row is asking. View-local, unlike the sheet's own presentation flag: this dialog and
    /// the row that raises it live in the same body, so nothing can tear one down without the other.
    @State private var isConfirmingRemoval = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    picker()
                } header: {
                    header
                } footer: {
                    Text("editor.signature.scopeHint", bundle: .module)
                }
                if hasExplicitChange {
                    Section {
                        Button(role: .destructive) { isConfirmingRemoval = true } label: {
                            Text("editor.signature.remove", bundle: .module)
                        }
                    } footer: {
                        Text(removalMessage, bundle: .module)
                    }
                }
            }
            .navigationTitle(Text(title, bundle: .module))
            .inlineNavigationTitleCompat()
            .toolbar { toolbarContent }
        }
        // Half height, and only half: this sheet asks one short question about one bar, and the score it is asking
        // about stays visible behind it — which is most of the point, since the change lands on what you can see.
        .presentationDetents([.medium])
        // Both presentations hang off the sheet's ROOT rather than off the Section or row that raises them — a
        // modifier attached inside the form is torn down when the form rebuilds, and the removal Section is exactly
        // the thing that disappears once the removal lands (repo gotcha, same as the instruments sheet's).
        .confirmationDialog(
            Text("editor.signature.remove.confirm.title", bundle: .module),
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible,
        ) {
            Button(role: .destructive) { finish(remove()) } label: {
                Text("editor.signature.remove.confirm.action", bundle: .module)
            }
            Button(role: .cancel) {} label: { L10n.Common.cancel }
        } message: {
            Text(removalMessage, bundle: .module)
        }
        .alert(
            Text("editor.signature.refusal.title", bundle: .module),
            isPresented: isRefusalPresented,
        ) {
            Button { viewModel.lastSignatureRefusal = nil } label: { L10n.Common.ok }
        } message: {
            refusalMessage
        }
    }

    // MARK: - Header

    /// The bar being changed and what it says today. An unnumbered bar (a pickup) states only the value: the score
    /// draws no number there, so there is none to quote.
    private var header: Text {
        if let number = viewModel.targetDisplayedMeasureNumber {
            Text("editor.signature.header \(number) \(currentValue)", bundle: .module)
        } else {
            Text("editor.signature.header.unnumbered \(currentValue)", bundle: .module)
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: {
                SheetActionLabel(.close, title: L10n.Common.cancel)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            // No discard confirmation here, unlike the drum layout and rehearsal mark sheets. What this one holds
            // is a picker's position — two taps to re-make — and an alert guarding that is friction with nothing
            // behind it.
            SheetConfirmButton(title: Text("editor.signature.apply", bundle: .module)) {
                finish(apply())
            }
        }
    }

    /// Closes on anything that isn't a refusal — see the type doc for why "didn't change the score" and "was refused"
    /// are not the same answer here.
    private func finish(_ changed: Bool) {
        if changed || viewModel.lastSignatureRefusal == nil {
            dismiss()
        }
    }

    // MARK: - Refusal

    private var isRefusalPresented: Binding<Bool> {
        Binding(
            get: { viewModel.lastSignatureRefusal != nil },
            set: { isPresented in
                guard !isPresented else { return }
                viewModel.lastSignatureRefusal = nil
            },
        )
    }

    /// The two refusals worth naming a bar for, and one sentence for everything else.
    ///
    /// `.cannotRemoveInitialSignature` and `.invalidTimeSignatureValue` fall to the generic line on purpose: neither
    /// is reachable from these sheets (the Remove section is hidden at bar 0, and the picker cannot produce a meter
    /// outside what can be written), so spelling them out would be writing copy for a state the UI does not have.
    private var refusalMessage: Text {
        switch viewModel.lastSignatureRefusal?.reason {
        case let .rebarWouldSplitTuplet(measureIndex):
            Text(
                "editor.signature.refusal.tuplet \(viewModel.displayedMeasureNumber(forMeasureIndex: measureIndex))",
                bundle: .module,
            )
        case let .rebarWouldDisplaceBarlineMarker(measureIndex):
            Text(
                "editor.signature.refusal.barline \(viewModel.displayedMeasureNumber(forMeasureIndex: measureIndex))",
                bundle: .module,
            )
        default:
            Text("editor.signature.refusal.generic", bundle: .module)
        }
    }
}

#if DEBUG
/// The fixtures behind both sheets' previews, in one place because the two sheets want the same score: three bars
/// where bar 1 declares a key AND a meter of its own, so "the target carries a change" and "the target inherits one"
/// are both one `targeting:` away.
@MainActor
enum EditorSignatureSheetPreviews {
    /// Bar 0 opens in C major / 4/4; bar 1 declares E♭ major and 3/4; bar 2 inherits both. Each bar actually holds
    /// what it declares, so nothing here depends on the engine tolerating a mis-filled bar.
    private static func score() -> Score {
        let opening = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .keySignature(KeySignature(concertKey: 0)),
        ] + rests(4))
        let change = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 3, denominator: 4)),
            .keySignature(KeySignature(concertKey: -3)),
        ] + rests(3))
        let staff = Staff(measures: [
            Measure(voices: [opening]),
            Measure(voices: [change]),
            Measure(voices: [Voice(elements: rests(3))]),
        ])
        return Score(division: 480, parts: [
            Part(id: "1", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
    }

    private static func rests(_ count: Int) -> [VoiceElement] {
        Array(repeating: .rest(duration: .quarter), count: count)
    }

    /// A session on that score with a rest picked in bar 1 (which declares changes of its own) or bar 2 (which
    /// inherits) — the selection is what supplies `targetMeasureIndex`.
    private static func viewModel(targetingBarWithChange: Bool) -> EditorViewModel {
        let viewModel = PreviewEditorFactory.makeViewModel()
        viewModel.beginSession(score: score())
        let measure = targetingBarWithChange ? 1 : 2
        viewModel.select(.rest(RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measure,
            voiceIndex: 0,
            elementIndex: targetingBarWithChange ? 2 : 0,
        )))
        return viewModel
    }

    static func keySheet(targetingBarWithChange: Bool) -> some View {
        EditorKeySignatureSheet(viewModel: viewModel(targetingBarWithChange: targetingBarWithChange))
    }

    static func timeSheet(targetingBarWithChange: Bool) -> some View {
        EditorTimeSignatureSheet(viewModel: viewModel(targetingBarWithChange: targetingBarWithChange))
    }

    /// The refusal alert, pre-armed: the binding reads `lastSignatureRefusal`, so seeding one puts the alert up on
    /// the first frame — which is the only way to see the longest of these sentences at its real width.
    static func timeSheetRefusing() -> some View {
        let viewModel = viewModel(targetingBarWithChange: true)
        viewModel.lastSignatureRefusal = EditRefusal(
            operation: "SetTimeSignature", reason: .rebarWouldSplitTuplet(measureIndex: 2),
        )
        return EditorTimeSignatureSheet(viewModel: viewModel)
    }
}
#endif
