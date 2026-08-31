import Domain
import Observation
import ScoreUI
import SwiftUI
import UtilityUI

// PARITY(android): M2 instruments sheet — part add/remove/reorder UI, plus the remap wiring for BOTH part-indexed
//   stores: the preferences row and the annotation layer's per-stroke anchors (`AnnotationLayers.remappingParts`,
//   which is shared Domain, so Android inherits the rule)

/// The score's instrumentation, editable: the parts it is written for, in order, each with a switch per staff for
/// whether that staff is currently shown.
///
/// Two different kinds of state sit in one list on purpose. The part list is the FILE — adding, deleting and
/// reordering write the score and land on the undo stack. The switches are the READER — hiding a staff changes what
/// this device draws and nothing else. They belong together because to a user they are one question ("what is in
/// this score, and what am I looking at"), and the wording keeps them apart: a switch says "show", a delete says the
/// notes go with it.
///
/// The visibility switches reach the Reader's own per-score settings through two seams on the view model
/// (`isStaffVisible` / `onToggleStaffVisibility`) that the App composition root fills in — the Editor cannot import
/// Reader.
@MainActor
struct EditorInstrumentsSheet: View {
    @Bindable var viewModel: EditorViewModel
    /// The catalog, presented over this sheet when `+` is tapped.
    @State private var isCatalogPresented = false
    /// The row a swipe-delete is asking about, which is also what drives the confirmation. A row rather than an
    /// index: the dialog has to say the part's name, and the index alone would make that a second lookup that could
    /// disagree with what was swiped.
    @State private var partPendingRemoval: EditorViewModel.PartRow?
    /// In-progress name edits, by part id. A row reads the score until it is typed into, and goes back to reading
    /// it once the draft is written — so an undo, or an edit arriving from elsewhere, is never masked by a stale
    /// buffer for a row nobody is editing.
    @State private var nameDrafts: [String: String] = [:]
    /// Which row's name field holds focus, by part id. Leaving a field is what commits it.
    @FocusState private var focusedPartID: String?
    /// The row whose abbreviation the alert is editing, and that edit's text.
    @State private var shortNameTarget: String?
    @State private var shortNameText = ""

    var body: some View {
        List {
            Section {
                ForEach(viewModel.partRows) { row in
                    partRow(row)
                }
                .onMove { source, destination in
                    viewModel.movePart(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    // Ask before removing: this takes the part's music with it. The dialog is what actually calls
                    // `removePart`.
                    guard let offset = offsets.first,
                          viewModel.partRows.indices.contains(offset)
                    else { return }
                    partPendingRemoval = viewModel.partRows[offset]
                }
                // A score must keep one part, and the engine refuses the last removal anyway — so the delete simply
                // isn't offered rather than being offered and rejected.
                .deleteDisabled(!viewModel.canRemovePart)
                // At the foot of the list rather than a `+` in the toolbar: the list is permanently in edit mode,
                // so its rows carry the delete and reorder affordances and the only thing missing is the other
                // end of the same job. Outside the `ForEach`, so edit mode leaves this row undecorated.
                Button { isCatalogPresented = true } label: {
                    Label {
                        Text("editor.instruments.add", bundle: .module)
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            } header: {
                Text("editor.instruments.title", bundle: .module)
            }
        }
        // Always on, so a part can be reordered or removed without an `EditButton` first — the same reasoning
        // as the creation wizard's list, and on the `List` itself because that is where edit mode is read
        // from (a section-scoped write renders no affordances at all). macOS has no `EditMode` — see
        // `activeEditModeCompat()`, which carries the parity marker for that gap.
        .activeEditModeCompat()
        .contentMargins(.top, 4, for: .scrollContent)
        // Opens at half height and pulls to full: half is enough to see what a small score holds, and an ensemble
        // of any size does not fit there. No navigation bar, no confirming button — the section header names the
        // list the way the Reader's inspectors name theirs, and every action here is already written to the score
        // by the time you see it, so there is nothing for a "done" to confirm. Swipe down closes it.
        .presentationDetents([.medium, .large])
        // Leaving a field is what writes it. Watched here rather than per row, because the value that changes is
        // one piece of state: the row losing focus is the PREVIOUS value, and the row gaining it is the new one.
        .onChange(of: focusedPartID) { previous, _ in
            guard let previous, let row = viewModel.partRows.first(where: { $0.id == previous }) else { return }
            commitName(row)
        }
        // Both presentations hang off this view's ROOT, never off a `Section` or a row: a modifier attached inside
        // the list is torn down the moment the list rebuilds — which adding or deleting a part does — and the sheet
        // closes on the frame it opened (repo gotcha).
        .sheet(isPresented: $isCatalogPresented) { catalogSheet }
        .alert(
            Text("editor.instruments.shortName", bundle: .module),
            isPresented: shortNamePresentationBinding,
        ) {
            TextField(text: $shortNameText) {
                Text("editor.instruments.shortName", bundle: .module)
            }
            Button { shortNameTarget = nil } label: { L10n.Common.cancel }
            Button(action: commitShortName) { L10n.Common.ok }
        } message: {
            Text("editor.instruments.shortName.message", bundle: .module)
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: isRemovalConfirmationPresented,
            titleVisibility: .visible,
            presenting: partPendingRemoval,
        ) { row in
            Button(role: .destructive) {
                // Re-resolved by `Part.id`, not by the index the swipe captured: the dialog is modal to this sheet
                // but not to the score, and a three-finger undo or a mirrored edit landing under it would leave that
                // index naming a different part. Missing entirely means the part is already gone — nothing to do.
                if let index = viewModel.partRows.first(where: { $0.id == row.id })?.index {
                    viewModel.removePart(at: index)
                }
                partPendingRemoval = nil
            } label: {
                L10n.Common.delete
            }
            Button(role: .cancel) { partPendingRemoval = nil } label: { L10n.Common.cancel }
        } message: { _ in
            Text("editor.instruments.delete.message", bundle: .module)
        }
    }

    // MARK: - Rows

    /// One part. A single-staff part — most of them — carries its switch inline, so the common row is one line with
    /// one control. A multi-staff part (a piano, an organ) needs one switch per staff, and those have to be named,
    /// so it stacks: the part's name, then a switch per staff underneath.
    @ViewBuilder
    private func partRow(_ row: EditorViewModel.PartRow) -> some View {
        if row.staffAddresses.count == 1, let address = row.staffAddresses.first {
            HStack {
                partName(row)
                Spacer(minLength: 8)
                visibilityButton(address)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                partName(row)
                ForEach(Array(row.staffAddresses.enumerated()), id: \.element) { index, address in
                    HStack {
                        Text("editor.instruments.showStaff \(index + 1)", bundle: .module)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        visibilityButton(address, staffNumber: index + 1)
                    }
                }
            }
        }
    }

    /// The staff's show/hide control — the same drawn eye and circular toggle the Reader's inspectors use, rather
    /// than a switch. A switch reads as a setting; this is the same question ("am I looking at this staff?") the
    /// Reader asks with an eye, and the two screens should not answer it with two different controls.
    private func visibilityButton(_ address: StaffAddress, staffNumber: Int? = nil) -> some View {
        let isVisible = viewModel.isStaffVisible(address)
        return Button {
            viewModel.onToggleStaffVisibility(address)
        } label: {
            EyeIcon(isOpen: isVisible, lineWidth: 1.6)
                .frame(width: 18, height: 13)
        }
        .buttonStyle(CircleBorderedToggleButtonStyle(isOn: isVisible))
        .accessibilityLabel(visibilityLabel(staffNumber: staffNumber))
    }

    private func visibilityLabel(staffNumber: Int?) -> Text {
        guard let staffNumber else {
            return Text("editor.instruments.staffVisibility", bundle: .module)
        }
        return Text("editor.instruments.showStaff \(staffNumber)", bundle: .module)
    }

    /// The part's name, editable in place, with its abbreviation and the instrument it plays beside it —
    /// "[なおき]  (な)  ピアノ".
    ///
    /// A score whose parts were renamed lists as names that say nothing about what plays them, which is what the
    /// instrument name is for; it is hidden when it would only repeat the field. The abbreviation is a chip rather
    /// than a second field, the same control the creation wizard uses for the same setting.
    ///
    /// The field writes on COMMIT, not per keystroke: every write here is a score edit with its own undo entry,
    /// and a name typed letter by letter would fill the stack with one entry per character.
    private func partName(_ row: EditorViewModel.PartRow) -> some View {
        HStack(spacing: 8) {
            TextField(text: nameBinding(row)) {
                Text("editor.instruments.partName", bundle: .module)
            }
            .focused($focusedPartID, equals: row.id)
            .onSubmit { commitName(row) }
            shortNameChip(row)
            if let instrumentName = row.instrumentName, instrumentName != row.name {
                Text(instrumentName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The row's field text: the draft while it is being typed, the score's own name otherwise. Keyed by part id
    /// rather than index — the list can be reordered while a field holds focus.
    private func nameBinding(_ row: EditorViewModel.PartRow) -> Binding<String> {
        Binding(
            get: { nameDrafts[row.id] ?? row.name },
            set: { nameDrafts[row.id] = $0 },
        )
    }

    /// Writes the draft to the score and drops it, so the row goes back to reading the score. Re-resolved by id,
    /// because the index the row was drawn with can have moved under a reorder or an undo since.
    private func commitName(_ row: EditorViewModel.PartRow) {
        guard let draft = nameDrafts.removeValue(forKey: row.id),
              let current = viewModel.partRows.first(where: { $0.id == row.id })
        else { return }
        viewModel.renamePart(at: current.index, longName: draft, shortName: current.shortName)
    }

    /// The part's abbreviation, shown and edited in one control — see the creation wizard's copy for why a chip
    /// rather than a second field. An em dash stands in for a part that carries none, which is a real setting:
    /// no label at all from the second system on.
    private func shortNameChip(_ row: EditorViewModel.PartRow) -> some View {
        Button {
            shortNameTarget = row.id
            shortNameText = row.shortName ?? ""
        } label: {
            Text(row.shortName ?? "—")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color(.tertiarySystemFill), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("editor.instruments.shortName", bundle: .module))
    }

    // MARK: - Toolbar / catalog

    /// The shared instrument catalog. The picked instrument's name is overridden with the localized catalog name —
    /// `partPlan()` carries the English one — so a part added here is named the way the new-score wizard names one.
    ///
    /// No duplicate numbering: adding a second violin gives you two rows both called "Violin". Numbering them would
    /// mean renaming parts that already exist, which is a score-level rename this sheet deliberately does not do.
    private var catalogSheet: some View {
        NavigationStack {
            InstrumentCatalogPicker { instrument in
                var plan = instrument.partPlan()
                plan.longName = localizedInstrumentName(instrument)
                viewModel.addPart(plan)
                isCatalogPresented = false
            }
            .navigationTitle(Text("editor.instruments.add", bundle: .module))
            .inlineNavigationTitleCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { isCatalogPresented = false } label: { L10n.Common.cancel }
                }
            }
        }
    }

    // MARK: - Deletion confirmation

    private var deletionTitle: Text {
        Text("editor.instruments.delete.title \(partPendingRemoval?.name ?? "")", bundle: .module)
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

    /// Writes the edited abbreviation, keeping the long name as it stands. Re-resolved by id for the reason the
    /// deletion dialog is: the alert is modal to this sheet but not to the score.
    private func commitShortName() {
        defer { shortNameTarget = nil }
        guard let shortNameTarget,
              let row = viewModel.partRows.first(where: { $0.id == shortNameTarget })
        else { return }
        viewModel.renamePart(at: row.index, longName: row.name, shortName: shortNameText)
    }

    private var isRemovalConfirmationPresented: Binding<Bool> {
        Binding(
            get: { partPendingRemoval != nil },
            set: { isPresented in
                guard !isPresented else { return }
                partPendingRemoval = nil
            },
        )
    }
}

#if DEBUG
/// Stands in for the Reader's layout settings, which is where staff visibility really lives. `@Observable` for the
/// same reason the real one is: the switches have to move when the value behind them does.
@MainActor
@Observable
private final class PreviewStaffVisibility {
    var hidden: Set<StaffAddress> = [StaffAddress(partIndex: 2, staffIndexInPart: 1)]

    func toggle(_ address: StaffAddress) {
        if hidden.contains(address) {
            hidden.remove(address)
        } else {
            hidden.insert(address)
        }
    }
}

/// A three-part score — one of them two-staffed, so both row shapes are on screen at once.
@MainActor
private func previewInstrumentsViewModel() -> EditorViewModel {
    let viewModel = PreviewEditorFactory.makeViewModel()
    viewModel.beginSession(score: Score.blank(BlankScoreTemplate(
        title: "Preview",
        parts: [
            BlankScoreTemplate.PartPlan(
                instrumentID: "flute", longName: "Flute", shortName: "Fl.",
                staves: [BlankScoreTemplate.StaffPlan(clefType: "G")],
            ),
            BlankScoreTemplate.PartPlan(
                instrumentID: "violin", longName: "Violin", shortName: "Vln.",
                staves: [BlankScoreTemplate.StaffPlan(clefType: "G")],
            ),
            BlankScoreTemplate.PartPlan(
                instrumentID: "piano", longName: "Piano", shortName: "Pno.",
                staves: [
                    BlankScoreTemplate.StaffPlan(clefType: "G"),
                    BlankScoreTemplate.StaffPlan(clefType: "F"),
                ],
            ),
        ],
        measureCount: 4,
    )))
    // Stands in for the App's wiring: the piano's lower staff starts hidden, so the "off" state is visible here too.
    let visibility = PreviewStaffVisibility()
    viewModel.isStaffVisible = { !visibility.hidden.contains($0) }
    viewModel.onToggleStaffVisibility = { visibility.toggle($0) }
    return viewModel
}

#Preview("Instruments") {
    EditorInstrumentsSheet(viewModel: previewInstrumentsViewModel())
}
#endif
