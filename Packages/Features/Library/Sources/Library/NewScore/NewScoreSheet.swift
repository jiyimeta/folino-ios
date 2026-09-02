import Domain
import Observation
import ScoreUI
import SwiftUI
import UtilityUI

// PARITY(android): M2 ensemble wizard — instrumentation list, templates, clone-from-existing on Android's creation flow

/// The "New score" wizard: a plain `Form` collecting the fields `NewScoreForm` maps to a `BlankScoreTemplate`.
/// Presented as a sheet from `LibraryRootPresentations`; Create hands the built form to
/// `LibraryViewModel.createScore(from:)`, which owns dismissal on success. On failure the sheet stays up (the typed
/// form isn't lost) and `currentError` is surfaced by this view's own alert — `LibraryRootPresentations`'
/// `ImportErrorAlert` is attached to the screen underneath this sheet, and SwiftUI won't present an alert from a view
/// that is already presenting a sheet, so the shared alert can't be reused here.
@MainActor
struct NewScoreSheet: View {
    let viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    /// Internal rather than private, here and below, because the instrumentation half of this view lives in
    /// `NewScoreSheet+Instrumentation.swift` and `private` is file-scoped.
    @State var form: NewScoreForm
    /// Whether one of the number-pad fields is being edited. A number pad has no return key, so without a
    /// keyboard toolbar to dismiss it there is no way back to the Create button on a phone.
    @FocusState private var isEditingNumber: Bool
    /// The row whose abbreviation is being edited, and the text of that edit. Held by id rather than index: the
    /// list can be reordered while the alert is up, and an index would then name a different part.
    @State var shortNameTarget: NewScoreForm.PartDraft.ID?
    @State var shortNameText = ""
    /// Which picker is up, if any. One piece of state for all three because they share one `.sheet(item:)`:
    /// two `.sheet` modifiers on the same view is a long-standing source of SwiftUI presentation races, where
    /// dismissing one and presenting the other in the same runloop turn drops the second.
    @State var picker: PickerSheet?

    /// `.replace` swaps the whole instrumentation for one instrument ("start from an instrument"); `.append`
    /// adds a part to the list; `.sourceScore` copies an existing score's ensemble wholesale.
    ///
    /// Named `PickerSheet`, not `Picker`: a nested type called `Picker` shadows SwiftUI's inside this view, and
    /// the key/time `Picker`s below stop resolving.
    enum PickerSheet: Identifiable {
        case replace
        case append
        case sourceScore

        var id: Self {
            self
        }
    }

    /// `form` is injectable so previews can render the wizard with an ensemble already applied; the app always
    /// opens on a fresh form.
    init(viewModel: LibraryViewModel, form: NewScoreForm = NewScoreForm()) {
        self.viewModel = viewModel
        _form = State(initialValue: form)
    }

    var body: some View {
        NavigationStack {
            Form {
                titleSection
                instrumentationSection
                layoutSection
                lengthSection
            }
            // Always on, so the instrumentation list can be reordered and deleted from without an `EditButton`
            // first. On the `Form` rather than on that one section: a `List` reads edit mode from its own
            // environment, not from each row's, so a section-scoped write renders no affordances at all
            // (verified in the preview). Nothing else in this form declares `onMove` / `onDelete`, so nothing
            // else gains an affordance from it.
            //
            // macOS gets neither affordance from this — it has no edit mode — but reordering is believed to still
            // work there, because `.onMove` alone makes a row draggable on a macOS `List` (measured, Task 15 — the
            // drag half; the on-screen drop is not yet hand-verified, see the marker on that helper). Deleting an
            // instrument is what the Mac is definitely left without; that gap carries the marker on this helper.
            .activeEditModeCompat()
            .navigationTitle(Text("library.newScore.title", bundle: .module))
            .inlineNavigationTitleCompat()
            .toolbar { toolbarContent }
        }
        .sheet(item: $picker) { picker in
            switch picker {
            case .replace: catalogSheet(replacing: true)
            case .append: catalogSheet(replacing: false)
            case .sourceScore: sourceScoreSheet
            }
        }
        .alert(
            Text("library.title", bundle: .module),
            isPresented: errorPresentationBinding,
            presenting: viewModel.currentError,
        ) { _ in
            Button { viewModel.currentError = nil } label: {
                L10n.Common.ok
            }
        } message: { error in
            Text(describeLibraryError(error))
        }
        // On the ROOT, like the error alert above and for the same reason the pickers are: a presentation attached
        // inside the list is torn down when the list rebuilds, which every rename does.
        .alert(
            Text("library.newScore.field.shortName", bundle: .module),
            isPresented: shortNamePresentationBinding,
        ) {
            TextField(text: $shortNameText) {
                Text("library.newScore.field.shortName", bundle: .module)
            }
            Button { shortNameTarget = nil } label: { L10n.Common.cancel }
            Button(action: commitShortName) { L10n.Common.ok }
        } message: {
            Text("library.newScore.field.shortName.message", bundle: .module)
        }
    }

    private var shortNamePresentationBinding: Binding<Bool> {
        Binding(
            get: { shortNameTarget != nil },
            set: { isPresented in
                guard !isPresented else { return }
                shortNameTarget = nil
            },
        )
    }

    /// Writes the edited abbreviation back to its row, resolved by id — the list can be reordered while the alert
    /// is up. An empty value is stored as `nil`, which is what engraves no label from the second system on: it is
    /// a choice a score can make, not a missing entry to be filled in with a default.
    private func commitShortName() {
        defer { shortNameTarget = nil }
        guard let shortNameTarget,
              let index = form.instrumentation.firstIndex(where: { $0.id == shortNameTarget })
        else { return }
        let trimmed = shortNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        form.instrumentation[index].shortName = trimmed.isEmpty ? nil : trimmed
    }

    /// Mirrors `LibraryRootPresentations.ImportErrorAlert.presentationBinding` — same shared `currentError`, its own
    /// presentation site so the alert actually reaches the screen while this sheet covers the root.
    private var errorPresentationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.currentError != nil },
            set: { isPresented in
                guard !isPresented else { return }
                viewModel.currentError = nil
            },
        )
    }

    private var titleSection: some View {
        Section {
            TextField(text: $form.title) {
                Text("library.newScore.field.title", bundle: .module)
            }
            TextField(text: $form.composer) {
                Text("library.newScore.field.composer", bundle: .module)
            }
        }
    }

    // MARK: - Layout / length

    /// Key signature, time signature and the optional pickup — the fields that shape the blank score's layout.
    /// The two signature controls are ScoreUI's, shared with the editor's signature-change sheets.
    private var layoutSection: some View {
        Section {
            KeySignaturePicker(selection: $form.concertKey)
            TimeSignaturePicker(numerator: $form.timeNumerator, denominator: $form.timeDenominator)
            NewScorePickupRow(
                pickup: $form.pickup,
                timeNumerator: form.timeNumerator,
                timeDenominator: form.timeDenominator,
            )
        } footer: {
            // Only once a pickup is actually chosen: the measure count is unambiguous without one, and this is
            // the cheapest place to say what it means with one (the count lives in the next section).
            if form.pickup != nil {
                Text("library.newScore.field.pickup.footer", bundle: .module)
            }
        }
    }

    /// Tempo and measure count — how long the blank score plays and how many bars it starts with. Typed rather
    /// than stepped: 200 bars is 168 taps away from the default, and both fields are numbers a user arrives with
    /// already in mind.
    private var lengthSection: some View {
        Section {
            numberField(
                Text("library.newScore.field.tempo", bundle: .module),
                value: $form.tempoBPM, in: 20 ... 300,
            )
            numberField(
                Text("library.newScore.field.measures", bundle: .module),
                value: $form.measureCount, in: 1 ... 200,
            )
        }
    }

    /// A whole number on a number pad, clamped to `range`.
    ///
    /// The clamp lives in the binding rather than in an `onChange`, because `TextField(value:format:)` writes its
    /// binding when editing *ends*, not per keystroke — so the binding sees the finished number, never the "1" on
    /// the way to "120". A number pad has no return key, which is what the keyboard toolbar below is for.
    ///
    /// `LabeledContent` rather than the field's own label: unlike `TextField(_:text:)`, the `value:format:label:`
    /// form does not draw its label in a `Form` row (it is the accessibility label), which left these two rows as
    /// bare numbers with nothing naming them.
    private func numberField(_ label: Text, value: Binding<Int>, in range: ClosedRange<Int>) -> some View {
        LabeledContent {
            TextField(value: clamping(value, to: range), format: .number) { label }
                .labelsHidden()
                .numberPadKeyboardCompat()
                .multilineTextAlignment(.trailing)
                .focused($isEditingNumber)
        } label: {
            label
        }
    }

    private func clamping(_ value: Binding<Int>, to range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) },
        )
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: { L10n.Common.cancel }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task { await viewModel.createScore(from: form) }
            } label: {
                Text("library.newScore.create", bundle: .module)
            }
            .disabled(form.template() == nil)
        }
        // Only while a number pad is up: the title and composer fields dismiss themselves with their return key,
        // and a Done bar over those would be a second way to do what the keyboard already does.
        ToolbarItemGroup(placement: .keyboard) {
            if isEditingNumber {
                Spacer()
                Button { isEditingNumber = false } label: { L10n.Common.done }
            }
        }
    }
}
