import Domain
import Observation
import ScoreUI
import SwiftUI
import UtilityUI

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
    /// Which catalog sheet is up, if any. `.replace` swaps the whole instrumentation for one instrument ("start
    /// from an instrument"); `.append` adds a part to the list.
    @State private var catalogPick: CatalogPick?
    @State private var isSourceScorePickerPresented = false

    private enum CatalogPick: Identifiable {
        case replace
        case append

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
        .sheet(item: $catalogPick) { pick in
            catalogSheet(for: pick)
        }
        .sheet(isPresented: $isSourceScorePickerPresented) {
            sourceScoreSheet
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
            Button { catalogPick = .append } label: {
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
            Button { isSourceScorePickerPresented = true } label: {
                Text("library.newScore.sameAsExisting", bundle: .module)
            }
            Button { catalogPick = .replace } label: {
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

    private func catalogSheet(for pick: CatalogPick) -> some View {
        NavigationStack {
            InstrumentCatalogPicker { instrument in
                switch pick {
                case .replace: form.replaceInstrumentation(with: instrument)
                case .append: form.addInstrument(instrument)
                }
                catalogPick = nil
            }
            .navigationTitle(Text(
                pick == .replace ? "library.newScore.chooseInstruments" : "library.newScore.addInstrument",
                bundle: .module,
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { catalogPick = nil } label: { L10n.Common.cancel }
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
                    Button { isSourceScorePickerPresented = false } label: { L10n.Common.cancel }
                }
            }
        }
    }

    /// Dismisses the picker BEFORE awaiting the parse: a load failure lands on `viewModel.currentError`, and the
    /// alert that presents it belongs to this sheet — it cannot reach the screen while the picker covers it.
    private func copyInstrumentation(from item: ScoreItem) {
        isSourceScorePickerPresented = false
        Task {
            guard let score = await viewModel.instrumentation(of: item) else { return }
            form.applyInstrumentation(of: score)
        }
    }

    // MARK: - Layout / length

    /// Key signature and time signature — the fields that shape the blank score's layout.
    private var layoutSection: some View {
        Section {
            Picker(selection: $form.concertKey) {
                ForEach(NewScoreForm.keyChoices, id: \.self) { key in
                    Text(Self.keyLabel(key)).tag(key)
                }
            } label: {
                Text("library.newScore.field.key", bundle: .module)
            }
            Picker(selection: timeChoiceIndex) {
                ForEach(Array(NewScoreForm.timeChoices.enumerated()), id: \.offset) { index, choice in
                    Text(verbatim: "\(choice.0)/\(choice.1)").tag(index)
                }
            } label: {
                Text("library.newScore.field.time", bundle: .module)
            }
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

    /// `(Int, Int)` tuples aren't `Hashable`, so the time-signature picker binds by index into `timeChoices` and
    /// writes both `timeNumerator`/`timeDenominator` back on selection.
    private var timeChoiceIndex: Binding<Int> {
        Binding(
            get: {
                NewScoreForm.timeChoices.firstIndex { $0.0 == form.timeNumerator && $0.1 == form.timeDenominator } ?? 0
            },
            set: { newIndex in
                guard NewScoreForm.timeChoices.indices.contains(newIndex) else { return }
                let choice = NewScoreForm.timeChoices[newIndex]
                form.timeNumerator = choice.0
                form.timeDenominator = choice.1
            },
        )
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

    /// Key names are universal note-letter spellings, not prose — written out once here rather than through the
    /// localization catalog. Circle of fifths, C-major center, matching `NewScoreForm.keyChoices`' order.
    private static func keyLabel(_ concertKey: Int) -> String {
        switch concertKey {
        case 0: "C / Am"
        case 1: "G / Em"
        case 2: "D / Bm"
        case 3: "A / F♯m"
        case 4: "E / C♯m"
        case 5: "B / G♯m"
        case 6: "F♯ / D♯m"
        case -1: "F / Dm"
        case -2: "B♭ / Gm"
        case -3: "E♭ / Cm"
        case -4: "A♭ / Fm"
        case -5: "D♭ / B♭m"
        case -6: "G♭ / E♭m"
        default: "\(concertKey)"
        }
    }
}
