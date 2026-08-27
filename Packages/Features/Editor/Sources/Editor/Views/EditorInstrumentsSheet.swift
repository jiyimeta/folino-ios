import Domain
import Observation
import ScoreUI
import SwiftUI
import UtilityUI

// PARITY(android): M2 instruments sheet — part add/remove/reorder UI, plus the remap wiring for BOTH part-indexed
// stores: the preferences row and the annotation layer's per-stroke anchors (`AnnotationLayers.remappingParts`, shared)

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
    @Environment(\.dismiss) private var dismiss
    /// The catalog, presented over this sheet when `+` is tapped.
    @State private var isCatalogPresented = false
    /// The row a swipe-delete is asking about, which is also what drives the confirmation. A row rather than an
    /// index: the dialog has to say the part's name, and the index alone would make that a second lookup that could
    /// disagree with what was swiped.
    @State private var partPendingRemoval: EditorViewModel.PartRow?

    var body: some View {
        NavigationStack {
            List {
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
                // A score must keep one part, and the engine refuses the last removal anyway — so the swipe simply
                // isn't offered rather than being offered and rejected.
                .deleteDisabled(!viewModel.canRemovePart)
            }
            .navigationTitle(Text("editor.instruments.title", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        // Both presentations hang off this view's ROOT, never off a `Section` or a row: a modifier attached inside
        // the list is torn down the moment the list rebuilds — which adding or deleting a part does — and the sheet
        // closes on the frame it opened (repo gotcha).
        .sheet(isPresented: $isCatalogPresented) { catalogSheet }
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
            Toggle(isOn: visibility(of: address)) {
                Text(row.name)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(row.name)
                ForEach(Array(row.staffAddresses.enumerated()), id: \.element) { index, address in
                    Toggle(isOn: visibility(of: address)) {
                        Text("editor.instruments.showStaff \(index + 1)", bundle: .module)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Reads and writes one staff's visibility through the App-wired seams. The setter ignores its argument and
    /// toggles: the store the seam points at exposes a flip, not an assignment, and a switch can only ever ask for
    /// the value it isn't already showing.
    private func visibility(of address: StaffAddress) -> Binding<Bool> {
        Binding(
            get: { viewModel.isStaffVisible(address) },
            set: { _ in viewModel.onToggleStaffVisibility(address) },
        )
    }

    // MARK: - Toolbar / catalog

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        // Reordering needs edit mode, and nothing else in this sheet does — same placement reasoning as the new-score
        // wizard's instrumentation section, one level up because here the list IS the sheet.
        ToolbarItem(placement: .topBarLeading) {
            EditButton()
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { isCatalogPresented = true } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(Text("editor.instruments.add", bundle: .module))
        }
        ToolbarItem(placement: .confirmationAction) {
            Button { dismiss() } label: { L10n.Common.done }
        }
    }

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
            .navigationBarTitleDisplayMode(.inline)
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
