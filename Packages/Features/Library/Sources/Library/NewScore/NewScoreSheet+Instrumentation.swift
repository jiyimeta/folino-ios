import Domain
import ScoreUI
import SwiftUI
import UtilityUI

// The instrumentation half of the creation wizard: the list of parts, the rows it draws, and the two pickers that
// seed it. Split out of `NewScoreSheet.swift` to keep that file inside SwiftLint's file-length budget — the same
// reason `EditorTopBarView+Instruments.swift` exists.

extension NewScoreSheet {
    // MARK: - Instrumentation

    /// The parts the new score is built from, as an always-editable list under the header's seeding menu.
    ///
    /// The list is permanently in edit mode rather than behind an `EditButton` (the form turns it on; see `body`):
    /// reordering and deleting are what this list is for, and a button whose only job is to switch them on is a
    /// tap in the way. Edit mode decorates the `ForEach` rows alone, so the "Add instrument" row below them keeps
    /// its plain appearance — the same reason it can stay in the section instead of being exiled to the header.
    var instrumentationSection: some View {
        Section {
            // Over the bindings, not the values: each row's name is edited in place.
            ForEach($form.instrumentation) { draft in
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
                // `.textCase(nil)`: a section header uppercases its text, and a template name is a name.
                templateMenu
                    .textCase(nil)
            }
        }
    }

    /// Seeds the instrumentation list — a ready-made template, an existing score's ensemble, or a single
    /// instrument — and doubles as the display of what the list currently *is*: `instrumentationSource` names the
    /// template it came from, demoting itself to "Custom" the moment the user reorders or deletes a row. So the
    /// header says both what can be picked and what is picked, in one control.
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
            HStack(spacing: 3) {
                Text(Self.instrumentationSourceKey(form.instrumentationSource), bundle: .module)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.subheadline)
            // A section header is short; without the padding the menu's tap target is barely taller than the
            // text itself.
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
    }

    /// One part: its name, editable in place, with what it actually *is* alongside.
    ///
    /// A score whose parts were renamed — five staves called "なおき", "つかさ"… that are all pianos — clones into
    /// rows whose names say nothing about the instruments, which is why the instrument's own name is shown next
    /// to them. It is hidden when it would only repeat what the field already says.
    private func partRow(_ draft: Binding<NewScoreForm.PartDraft>) -> some View {
        HStack {
            TextField(text: draft.name, prompt: draft.wrappedValue.instrumentName.map { Text($0) }) {
                Text("library.newScore.field.partName", bundle: .module)
            }
            shortNameChip(draft.wrappedValue)
            if let instrumentName = trailingInstrumentName(draft.wrappedValue) {
                Text(instrumentName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Only worth saying for a multi-staff part: a single staff is what every row is assumed to be.
            if draft.wrappedValue.plan.staves.count > 1 {
                Text("library.newScore.staffCount \(draft.wrappedValue.plan.staves.count)", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // A `List` insets a row's separator to line up with its first text, and it does not count a `TextField`
        // as one — so the separator started at the trailing instrument name, floating in the middle of the row.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }

    /// The part's staff abbreviation, shown and edited in one control.
    ///
    /// It is worth showing at all because nothing else does: the abbreviation is what gets engraved at the left of
    /// every system after the first, and until now the wizard gave no way to see it, let alone change it. A chip
    /// rather than a second text field on the row — it is one to four characters that most parts never need
    /// touched (a violin's "Vln." is right as it stands, even after the part is renamed "1st Violin"), and a bare
    /// narrow field would spend the name's width on it while still needing a label to explain itself.
    ///
    /// An em dash stands in for an empty one, which is a real setting rather than a missing value: a part with no
    /// abbreviation engraves no label from the second system on, and some scores want exactly that.
    private func shortNameChip(_ draft: NewScoreForm.PartDraft) -> some View {
        Button {
            shortNameTarget = draft.id
            shortNameText = draft.shortName ?? ""
        } label: {
            Text(draft.shortName ?? "—")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color(.tertiarySystemFill), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("library.newScore.field.shortName", bundle: .module))
    }

    /// The instrument's name to show beside a part — `nil` when it would be a repetition: when the part is simply
    /// named after its instrument (every catalog pick starts that way), and when the name is empty, where the
    /// field's own placeholder is already showing it.
    private func trailingInstrumentName(_ draft: NewScoreForm.PartDraft) -> String? {
        guard let instrumentName = draft.instrumentName else { return nil }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != instrumentName else { return nil }
        return instrumentName
    }

    /// The catalog picker, in either of its two modes. Takes a `Bool` rather than the case so there is no
    /// `.sourceScore` branch here to leave unhandled — that case never reaches this function.
    func catalogSheet(replacing: Bool) -> some View {
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
    var sourceScoreSheet: some View {
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

    /// What the header's menu shows for the list as it currently stands: the name of the template it was seeded
    /// from, that it was copied off another score, or "Custom" once a hand edit has demoted it.
    private static func instrumentationSourceKey(_ source: String) -> LocalizedStringKey {
        switch source {
        case NewScoreForm.customSource: "library.newScore.instrumentation.custom"
        case NewScoreForm.clonedSource: "library.newScore.instrumentation.cloned"
        default: templateNameKey(source)
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
