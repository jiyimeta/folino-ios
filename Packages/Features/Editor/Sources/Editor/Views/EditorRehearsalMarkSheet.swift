import Foundation
import SwiftUI
import UtilityUI

// PARITY(android): M4 rehearsal mark editing — Android needs the sheet UI; ssm logic is shared

/// Names the target bar. A free-form field seeded with the bar's own mark (a rename) or the next letter, plus the
/// destructive row that takes an existing mark back out.
///
/// Its own view rather than a use of `EditorSignatureSheet`'s scaffold: that one is built around a picker, an
/// "applies until the next change" span, a removal confirmation and a refusal alert, and a rehearsal mark has none
/// of those — it is a point, not a span; its removal is one undoable byte; and no refusal is reachable from here
/// (see `EditorViewModel+RehearsalMarks.swift`).
@MainActor
struct EditorRehearsalMarkSheet: View {
    let viewModel: EditorViewModel
    /// The typed text, seeded once from the target bar. `@State` rather than a computed binding on the view model:
    /// typing must not write the score — Apply is what writes it.
    @State private var text: String
    /// What the field was seeded with, so ✕ can tell "typed something and changed their mind" from "opened it and
    /// backed out" and only interrupt for the first.
    @State private var seed: String
    @State private var isDiscardConfirmationPresented = false

    @Environment(\.dismiss) private var dismiss

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
        let suggestion = viewModel.suggestedRehearsalMarkText
        _text = State(initialValue: suggestion)
        _seed = State(initialValue: suggestion)
    }

    private var hasChanges: Bool {
        text != seed
    }

    /// Whitespace alone is not a mark, and the engine refuses it. Gating Apply here is what keeps that refusal
    /// unreachable from the UI.
    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // No `textInputAutocapitalization` override: `.characters` would suit "A" / "B" and wreck
                    // "Bridge" and "1サビ", which this field has to take just as readily. The seeded letter is
                    // already uppercase, so the default costs nothing.
                    TextField(text: $text) {
                        Text("editor.rehearsalMark.title", bundle: .module)
                    }
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(apply)
                } header: {
                    header
                } footer: {
                    Text("editor.rehearsalMark.footer", bundle: .module)
                }
                if viewModel.targetRehearsalMarkText != nil {
                    Section {
                        Button(role: .destructive) {
                            viewModel.removeRehearsalMark()
                            dismiss()
                        } label: {
                            Text("editor.rehearsalMark.remove", bundle: .module)
                        }
                    }
                }
            }
            .navigationTitle(Text("editor.rehearsalMark.title", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .interactiveDismissDisabled(hasChanges)
            .alert(
                Text("editor.discardAlert.title", bundle: .module),
                isPresented: $isDiscardConfirmationPresented,
            ) {
                Button(role: .cancel) {} label: {
                    Text("editor.discardAlert.keepEditing", bundle: .module)
                }
                Button(role: .destructive) { dismiss() } label: {
                    Text("editor.discardAlert.discard", bundle: .module)
                }
            }
        }
        // Same as the signature sheets: one short question about one bar, asked over the score it is about.
        .presentationDetents([.medium])
    }

    /// The bar being named. An unnumbered bar (a pickup) is named "this measure": the score draws no number there,
    /// so there is none to quote — the same rule `EditorSignatureSheet`'s header follows.
    private var header: Text {
        if let number = viewModel.targetDisplayedMeasureNumber {
            Text("editor.rehearsalMark.header \(number)", bundle: .module)
        } else {
            Text("editor.rehearsalMark.header.unnumbered", bundle: .module)
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                if hasChanges {
                    isDiscardConfirmationPresented = true
                } else {
                    dismiss()
                }
            } label: {
                SheetActionLabel(.close, title: L10n.Common.cancel)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            SheetConfirmButton(title: Text("editor.rehearsalMark.apply", bundle: .module), action: apply)
                .disabled(trimmed.isEmpty)
        }
    }

    /// Writes the field and closes. The write's `false` is deliberately discarded — unlike the signature sheet
    /// there is nothing to keep this sheet up FOR, since a `false` here only ever means the bar already reads
    /// exactly this, which is the state the user asked for.
    ///
    /// The empty guard is for `onSubmit`, which fires on the keyboard's Done regardless of what Apply's own
    /// `disabled` says.
    private func apply() {
        guard !trimmed.isEmpty else { return }
        viewModel.setRehearsalMark(text: trimmed)
        dismiss()
    }
}

#if DEBUG
// Only the preview fixture below builds a `Score`; the sheet itself reads everything through `EditorViewModel`.
import SheetMusicCore

#Preview("Rehearsal mark — new") {
    EditorRehearsalMarkSheetPreviews.sheet(withExistingMark: false)
}

#Preview("Rehearsal mark — rename") {
    EditorRehearsalMarkSheetPreviews.sheet(withExistingMark: true)
}

/// The fixture behind both previews: three bars of quarter rests with bar 1 selected, optionally already carrying a
/// mark so the destructive Section is one flag away.
///
/// The score is built inline rather than shared, because the Editor package has no common preview fixture —
/// `EditorSignatureSheetPreviews.score()` next door builds its own for the same reason, and `EditorFixtures` is in
/// the test target and unreachable from here.
@MainActor
enum EditorRehearsalMarkSheetPreviews {
    private static func score() -> Score {
        let staff = Staff(measures: (0 ..< 3).map { _ in
            Measure(voices: [Voice(elements: Array(repeating: .rest(duration: .quarter), count: 4))])
        })
        return Score(division: 480, parts: [
            Part(id: "1", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
    }

    static func sheet(withExistingMark: Bool) -> some View {
        let viewModel = PreviewEditorFactory.makeViewModel()
        viewModel.beginSession(score: score())
        viewModel.select(.rest(RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 1, voiceIndex: 0, elementIndex: 0,
        )))
        if withExistingMark {
            viewModel.setRehearsalMark(text: "B")
        }
        return EditorRehearsalMarkSheet(viewModel: viewModel)
    }
}
#endif
