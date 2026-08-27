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
    @State private var form: NewScoreForm
    /// Which picker is up, if any. One piece of state for all three because they share one `.sheet(item:)`:
    /// two `.sheet` modifiers on the same view is a long-standing source of SwiftUI presentation races, where
    /// dismissing one and presenting the other in the same runloop turn drops the second.
    @State private var picker: PickerSheet?

    /// `.replace` swaps the whole instrumentation for one instrument ("start from an instrument"); `.append`
    /// adds a part to the list; `.sourceScore` copies an existing score's ensemble wholesale.
    ///
    /// Named `PickerSheet`, not `Picker`: a nested type called `Picker` shadows SwiftUI's inside this view, and
    /// the key/time `Picker`s below stop resolving.
    private enum PickerSheet: Identifiable {
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
            .navigationTitle(Text("library.newScore.title", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - Instrumentation

    /// The parts the new score is built from: a seeding menu (ready-made templates, an existing score's ensemble,
    /// or a single instrument) over the editable list itself.
    private var instrumentationSection: some View {
        Section {
            templateMenu
            ForEach(form.instrumentation) { draft in
                partRow(draft)
            }
            .onMove { source, destination in
                form.moveInstruments(fromOffsets: source, toOffset: destination)
            }
            .onDelete { offsets in
                form.removeInstruments(at: offsets)
            }
            Button { picker = .append } label: {
                Label {
                    Text("library.newScore.addInstrument", bundle: .module)
                } icon: {
                    Image(systemName: "plus")
                }
            }
        } header: {
            HStack {
                Text("library.newScore.section.instrumentation", bundle: .module)
                Spacer()
                // Reordering needs edit mode, and this sheet has no other reason to enter it — so the button
                // lives on the one section it affects rather than in the toolbar, where it would read as
                // applying to the whole form.
                EditButton()
                    .textCase(nil)
            }
        }
    }

    private var templateMenu: some View {
        Menu {
            ForEach(ScoreCreationTemplate.all) { template in
                Button { form.applyTemplate(template) } label: {
                    Text(Self.templateNameKey(template.id), bundle: .module)
                }
            }
            Divider()
            Button { picker = .sourceScore } label: {
                Text("library.newScore.sameAsExisting", bundle: .module)
            }
            Button { picker = .replace } label: {
                Text("library.newScore.chooseInstruments", bundle: .module)
            }
        } label: {
            HStack {
                Text("library.newScore.template", bundle: .module)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
    }

    private func partRow(_ draft: NewScoreForm.PartDraft) -> some View {
        HStack {
            Text(draft.displayName)
            Spacer()
            // Only worth saying for a multi-staff part: a single staff is what every row is assumed to be.
            if draft.plan.staves.count > 1 {
                Text("library.newScore.staffCount \(draft.plan.staves.count)", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The catalog picker, in either of its two modes. Takes a `Bool` rather than the case so there is no
    /// `.sourceScore` branch here to leave unhandled — that case never reaches this function.
    private func catalogSheet(replacing: Bool) -> some View {
        NavigationStack {
            InstrumentCatalogPicker { instrument in
                if replacing {
                    form.replaceInstrumentation(with: instrument)
                } else {
                    form.addInstrument(instrument)
                }
                picker = nil
            }
            .navigationTitle(Text(
                replacing ? "library.newScore.chooseInstruments" : "library.newScore.addInstrument",
                bundle: .module,
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { picker = nil } label: { L10n.Common.cancel }
                }
            }
        }
    }

    /// Pick an existing score to copy the instrumentation from. Soft-deleted rows are already out of
    /// `repository.scoreItems`, so nothing extra filters them here.
    private var sourceScoreSheet: some View {
        NavigationStack {
            List(viewModel.repository.scoreItems) { item in
                Button { copyInstrumentation(from: item) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).foregroundStyle(.primary)
                        if let summary = item.instrumentationSummary, !summary.isEmpty {
                            Text(summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
            }
            .overlay {
                if viewModel.repository.scoreItems.isEmpty {
                    Text("library.newScore.noScoresToCopy", bundle: .module)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(Text("library.newScore.chooseSourceScore", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { picker = nil } label: { L10n.Common.cancel }
                }
            }
        }
    }

    /// Dismisses the picker BEFORE awaiting the parse: a load failure lands on `viewModel.currentError`, and the
    /// alert that presents it belongs to this sheet — it cannot reach the screen while the picker covers it.
    private func copyInstrumentation(from item: ScoreItem) {
        picker = nil
        Task {
            guard let score = await viewModel.instrumentation(of: item) else { return }
            form.applyInstrumentation(of: score)
        }
    }

    // MARK: - Layout / length

    /// Key signature, time signature and the optional pickup — the fields that shape the blank score's layout.
    /// The two signature controls are ScoreUI's, shared with the editor's signature-change sheets.
    private var layoutSection: some View {
        Section {
            KeySignaturePicker(selection: $form.concertKey)
            TimeSignaturePicker(numerator: $form.timeNumerator, denominator: $form.timeDenominator)
            pickupRow
        } footer: {
            // Only once a pickup is actually chosen: the measure count is unambiguous without one, and this is
            // the cheapest place to say what it means with one (the count lives in the next section).
            if form.pickup != nil {
                Text("library.newScore.field.pickup.footer", bundle: .module)
            }
        }
    }

    /// The opening bar's length, or none. Rebuilt from the current meter on every change, so it never offers a
    /// pickup longer than the bar it opens; `NewScoreForm` retires a stale selection at the same moment.
    private var pickupRow: some View {
        Picker(selection: $form.pickup) {
            Text("library.newScore.field.pickup.none", bundle: .module).tag(Fraction?.none)
            ForEach(
                NewScoreForm.pickupChoices(
                    numerator: form.timeNumerator, denominator: form.timeDenominator,
                ),
                id: \.self,
            ) { choice in
                // Note values, not prose: "3/8" reads the same in every language folino ships.
                Text(verbatim: "\(choice.numerator)/\(choice.denominator)").tag(Fraction?.some(choice))
            }
        } label: {
            Text("library.newScore.field.pickup", bundle: .module)
        }
    }

    /// Tempo and measure count — how long the blank score plays and how many bars it starts with.
    private var lengthSection: some View {
        Section {
            Stepper(value: $form.tempoBPM, in: 20 ... 300) {
                LabeledContent {
                    Text(form.tempoBPM, format: .number)
                } label: {
                    Text("library.newScore.field.tempo", bundle: .module)
                }
            }
            Stepper(value: $form.measureCount, in: 1 ... 200) {
                LabeledContent {
                    Text(form.measureCount, format: .number)
                } label: {
                    Text("library.newScore.field.measures", bundle: .module)
                }
            }
        }
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
    }

    /// Template names live in this module's catalog, not in Domain — `ScoreCreationTemplate` stores nothing a user
    /// reads. The switch (rather than string interpolation into a key) keeps the catalog's keys greppable and makes
    /// a template added to Domain without a name a compile-time miss instead of a runtime raw key.
    private static func templateNameKey(_ id: String) -> LocalizedStringKey {
        switch id {
        case "solo-piano": "library.newScore.template.solo-piano"
        case "voice-piano": "library.newScore.template.voice-piano"
        case "satb": "library.newScore.template.satb"
        case "string-quartet": "library.newScore.template.string-quartet"
        default: LocalizedStringKey(id)
        }
    }
}
