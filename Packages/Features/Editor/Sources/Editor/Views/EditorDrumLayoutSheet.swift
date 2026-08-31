import EditorCore
import SwiftUI
import UtilityUI

/// Editing the drum pad's key layout: which instruments, in what order, on which row, in which voice
/// (drum note entry's §5.6).
///
/// One section per pad row, because that is what the user is arranging — the pad is rows of keys, and a single flat
/// list that the pad then chopped in half meant moving one instrument silently pushed another onto the next row.
/// Rows are added and removed whole; instruments are added and removed inside a row. Nothing caps a row's length:
/// a phone will squeeze what it must, an iPad has room for more, and a row too crowded to read is one the user can
/// thin out themselves.
///
/// Driven from LOCAL state and persisted separately — never through `@AppStorage` into the layout, which routes
/// the change through `UserDefaults` and lands it outside `withAnimation` (see `DrumPadLayoutStore`).
struct EditorDrumLayoutSheet: View {
    /// What the sheet opened on, so Cancel has something to go back to and the pad is only told about a layout the
    /// user kept.
    let initial: DrumPadLayout
    let apply: (DrumPadLayout) -> Void

    @State private var layout: DrumPadLayout
    @State private var picking: Picking?
    @State private var isDiscardConfirmationPresented = false
    @Environment(\.dismiss) private var dismiss

    /// Arranging fourteen keys across rows is not something to lose to a stray tap on ✕, or to a swipe down.
    private var hasChanges: Bool {
        layout != initial
    }

    /// What the instrument list, when it is open, is being opened for.
    private enum Picking: Identifiable {
        /// Re-instrument the key at this pitch, keeping its place and its voice.
        case replace(pitch: Int)
        /// Append an instrument to this row.
        case append(row: Int)

        var id: String {
            switch self {
            case let .replace(pitch): "replace-\(pitch)"
            case let .append(row): "append-\(row)"
            }
        }
    }

    init(initial: DrumPadLayout, apply: @escaping (DrumPadLayout) -> Void) {
        self.initial = initial
        self.apply = apply
        _layout = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            form
                .activeEditModeCompat()
                .navigationTitle(Text("editor.drum.layout.title", bundle: .module))
                .inlineNavigationTitleCompat()
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
                .sheet(item: $picking) { picking in
                    EditorDrumInstrumentPicker(current: currentPitch(for: picking), taken: takenPitches) { pitch in
                        pick(pitch, for: picking)
                    }
                }
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker(String(localized: "editor.drum.layout.preset", bundle: .module), selection: preset) {
                    Text("editor.drum.layout.preset.singleVoice", bundle: .module)
                        .tag(DrumVoicePreset.singleVoice)
                    Text("editor.drum.layout.preset.handsAndFeet", bundle: .module)
                        .tag(DrumVoicePreset.handsAndFeet)
                }
            }

            ForEach(layout.rows.indices, id: \.self) { index in
                rowSection(index)
            }

            if layout.rowCount < DrumPadLayout.maxRowCount {
                Section {
                    Button {
                        layout.rows.append([])
                    } label: {
                        Label {
                            Text("editor.drum.layout.addRow", bundle: .module)
                        } icon: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
        }
    }

    /// One pad row. Drag to reorder within it, tap an instrument to swap it, tap its voice badge to flip 1 ↔ 2,
    /// swipe to remove it. Dragging between rows is not offered — a `List` cannot move a row across sections — so
    /// the way to move an instrument up a row is to delete it and add it there.
    private func rowSection(_ index: Int) -> some View {
        Section {
            ForEach(layout.rows[index]) { key in
                row(for: key)
            }
            .onMove { layout.rows[index].move(fromOffsets: $0, toOffset: $1) }
            .onDelete { layout.rows[index].remove(atOffsets: $0) }

            Button {
                picking = .append(row: index)
            } label: {
                Label {
                    Text("editor.drum.layout.addInstrument", bundle: .module)
                } icon: {
                    Image(systemName: "plus")
                }
            }
        } header: {
            HStack {
                Text("editor.drum.layout.row \(index + 1)", bundle: .module)
                Spacer()
                // Only offered while there is more than one row: a pad with no instrument rows is not a pad.
                if layout.rowCount > 1 {
                    Button(role: .destructive) {
                        layout.rows.remove(at: index)
                    } label: {
                        Text("editor.drum.layout.removeRow", bundle: .module)
                    }
                    .textCase(nil)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(role: .cancel) {
                if hasChanges {
                    isDiscardConfirmationPresented = true
                } else {
                    dismiss()
                }
            } label: {
                SheetActionLabel(.close, title: Text("editor.drum.layout.cancel", bundle: .module))
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            SheetConfirmButton(title: Text("editor.drum.layout.done", bundle: .module)) {
                apply(layout)
                dismiss()
            }
        }
    }

    private func row(for key: DrumPadKey) -> some View {
        HStack {
            EditorDrumKeyIcon(pitch: key.pitch, label: shellLabels[key.pitch])
            Button {
                picking = .replace(pitch: key.pitch)
            } label: {
                Text(DrumKeyLabel.name(for: key))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            // A menu, not a toggle. The badge used to flip 1 ↔ 2 on tap, which reads as a label rather than a
            // control and gives no hint that two is all there is — a menu shows both voices and which one is on.
            Menu {
                Picker(selection: voice(of: key)) {
                    ForEach(0 ..< 2) { index in
                        Text("editor.drum.layout.voiceBadge \(index + 1)", bundle: .module).tag(index)
                    }
                } label: {
                    Text("editor.drum.layout.preset", bundle: .module)
                }
                .pickerStyle(.inline)
            } label: {
                Text("editor.drum.layout.voiceBadge \(key.voiceIndex + 1)", bundle: .module)
                    .font(.footnote)
                    .monospacedDigit()
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Editing

    /// The preset the current voices already spell, and applying a different one. Reading it back rather than
    /// storing a selection keeps the picker honest after a per-key flip: change one voice and the picker stops
    /// claiming a preset the layout no longer follows.
    private var preset: Binding<DrumVoicePreset> {
        Binding(
            get: {
                let single = DrumVoicePreset.singleVoice.applied(to: layout)
                return single == layout ? .singleVoice : .handsAndFeet
            },
            set: { layout = $0.applied(to: layout) },
        )
    }

    /// The same letters the pad puts on a drum's shell, so a row here and the key it becomes read alike.
    private var shellLabels: [Int: String] {
        DrumKeyLabel.shellLabels(for: layout.keys.map(\.pitch))
    }

    private var takenPitches: Set<Int> {
        Set(layout.keys.map(\.pitch))
    }

    private func currentPitch(for picking: Picking) -> Int? {
        switch picking {
        case let .replace(pitch): pitch
        case .append: nil
        }
    }

    private func voice(of key: DrumPadKey) -> Binding<Int> {
        Binding(
            get: { key.voiceIndex },
            set: { voiceIndex in
                guard let position = position(of: key.pitch) else { return }
                layout.rows[position.row][position.index].voiceIndex = voiceIndex
            },
        )
    }

    /// A pitch the layout already holds is refused rather than duplicated: two keys writing the same drum would
    /// toggle each other.
    private func pick(_ pitch: Int, for picking: Picking) {
        self.picking = nil
        switch picking {
        case let .replace(current):
            guard let position = position(of: current),
                  !takenPitches.contains(pitch) || pitch == current
            else { return }
            let voiceIndex = layout.rows[position.row][position.index].voiceIndex
            guard let replacement = DrumPadKey(gmPitch: pitch, voiceIndex: voiceIndex) else { return }
            layout.rows[position.row][position.index] = replacement
        case let .append(row):
            guard layout.rows.indices.contains(row),
                  !takenPitches.contains(pitch),
                  let key = DrumPadKey(gmPitch: pitch)
            else { return }
            layout.rows[row].append(key)
        }
    }

    private func position(of pitch: Int) -> (row: Int, index: Int)? {
        for (row, keys) in layout.rows.enumerated() {
            if let index = keys.firstIndex(where: { $0.pitch == pitch }) {
                return (row, index)
            }
        }
        return nil
    }
}

/// The drum's pad icon at list size, or nothing for a drum no icon is drawn for.
///
/// Blank rather than a stand-in: the list already names the instrument, and a placeholder glyph repeated down a
/// dozen rows would read as "these are all the same drum".
struct EditorDrumKeyIcon: View {
    let pitch: Int
    var label: String?

    var body: some View {
        Group {
            if let icon = DrumInstrumentIcon.forPitch(pitch) {
                DrumInstrumentIconView(icon: icon, label: label)
            }
        }
        .frame(width: 28, height: 28)
    }
}

/// The instrument list a row opens: every drum `GMDrumset` names, by pitch. A pitch already on the pad is shown
/// but not selectable — the pad cannot hold the same drum twice, and hiding it would make the list jump around
/// depending on what you had already chosen.
struct EditorDrumInstrumentPicker: View {
    let current: Int?
    let taken: Set<Int>
    let pick: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(DrumPadKey.allGMPitches, id: \.self) { pitch in
                Button {
                    pick(pitch)
                    dismiss()
                } label: {
                    HStack {
                        EditorDrumKeyIcon(pitch: pitch)
                        if let key = DrumPadKey(gmPitch: pitch) {
                            Text(DrumKeyLabel.name(for: key))
                        }
                        Spacer()
                        if pitch == current {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(pitch != current && taken.contains(pitch))
            }
            .navigationTitle(Text("editor.drum.layout.instrument", bundle: .module))
            .inlineNavigationTitleCompat()
        }
    }
}
