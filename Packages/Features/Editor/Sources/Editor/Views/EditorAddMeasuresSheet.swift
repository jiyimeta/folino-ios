import SwiftUI
import UtilityUI

/// How many bars to add, and where — the bulk form of the measure submenu's one-bar rows.
///
/// A sheet rather than a submenu of counts: a fixed list (1 / 2 / 4 / 8) cannot reach "thirty-two", and adding a
/// "Custom…" row to it would open this same sheet anyway, one level deeper. The one-bar rows stay in the menu, so
/// the common case never pays for this one.
///
/// The whole run lands as a single edit — see `EditorViewModel.appendMeasures(_:)`. Thirty bars added is one press
/// of undo, not thirty.
@MainActor
struct EditorAddMeasuresSheet: View {
    /// Where the new bars go. `beforeTarget` needs a target bar, which is why the picker can arrive disabled.
    enum Placement: Hashable {
        case end
        case beforeTarget
    }

    @Bindable var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var count = 4
    @State private var placement: Placement = .end
    @FocusState private var isEditingCount: Bool

    /// Same ceiling as the creation wizard's measure count — past it, a blank score is not what anyone is building.
    private static let countRange = 1 ... 200

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    countRow
                    placementRow
                } footer: {
                    // Only when it is the reason the picker is stuck on "at end": saying it unprompted would read
                    // as an error on a sheet that is working fine.
                    if viewModel.targetMeasureIndex == nil {
                        Text("editor.measure.addMany.noTarget", bundle: .module)
                    }
                }
            }
            .navigationTitle(Text("editor.measure.addMany.title", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .presentationDetents([.medium])
    }

    private var countRow: some View {
        LabeledContent {
            TextField(value: clampedCount, format: .number) {
                Text("editor.measure.addMany.count", bundle: .module)
            }
            .labelsHidden()
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .focused($isEditingCount)
        } label: {
            Text("editor.measure.addMany.count", bundle: .module)
        }
    }

    private var placementRow: some View {
        Picker(selection: $placement) {
            Text("editor.measure.addMany.atEnd", bundle: .module).tag(Placement.end)
            Text("editor.measure.addMany.beforeTarget", bundle: .module).tag(Placement.beforeTarget)
        } label: {
            Text("editor.measure.addMany.placement", bundle: .module)
        }
        // Without a target bar there is nothing to insert before, so the whole row goes rather than offering a
        // choice that cannot be taken. `placement` is already `.end` in that case and nothing can move it.
        .disabled(viewModel.targetMeasureIndex == nil)
    }

    /// The count field's binding, clamped on commit. `TextField(value:format:)` writes when editing ends rather
    /// than per keystroke, so the clamp sees the finished number — never the "3" on the way to "32".
    private var clampedCount: Binding<Int> {
        Binding(
            get: { count },
            set: { count = min(max($0, Self.countRange.lowerBound), Self.countRange.upperBound) },
        )
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: { L10n.Common.cancel }
        }
        ToolbarItem(placement: .confirmationAction) {
            EditorConfirmButton(label: Text("editor.measure.addMany.apply", bundle: .module), action: add)
        }
        // A number pad has no return key; without this there is no way to put it away on a phone.
        ToolbarItemGroup(placement: .keyboard) {
            if isEditingCount {
                Spacer()
                Button { isEditingCount = false } label: { L10n.Common.done }
            }
        }
    }

    private func add() {
        switch placement {
        case .end: viewModel.appendMeasures(count)
        case .beforeTarget: viewModel.insertMeasuresBeforeTarget(count)
        }
        dismiss()
    }
}

#if DEBUG
#Preview("Add measures") {
    EditorAddMeasuresSheet(viewModel: PreviewEditorFactory.makeViewModel())
}
#endif
