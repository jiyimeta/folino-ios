import EditorCore
import SwiftUI
import UtilityUI

/// Editing the drum pad's key layout: which instruments, in what order, on how many rows, in which voice
/// (drum note entry's §5.6).
///
/// Driven from LOCAL state and persisted separately — never through `@AppStorage` into the layout, which routes
/// the change through `UserDefaults` and lands it outside `withAnimation` (see `DrumPadLayoutStore`).
struct EditorDrumLayoutSheet: View {
    /// What the sheet opened on, so Cancel has something to go back to and the pad is only told about a layout the
    /// user kept.
    let initial: DrumPadLayout
    let apply: (DrumPadLayout) -> Void

    @State private var layout: DrumPadLayout
    @State private var pickingKeyID: Int?
    @Environment(\.dismiss) private var dismiss

    init(initial: DrumPadLayout, apply: @escaping (DrumPadLayout) -> Void) {
        self.initial = initial
        self.apply = apply
        _layout = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            form
            // Gap recorded on EditorInstrumentsSheet.swift's PARITY(macos) marker, not duplicated here.
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle(Text("editor.drum.layout.title", bundle: .module))
            .inlineNavigationTitleCompat()
            .toolbar { toolbarContent }
            .sheet(item: pickingKey) { key in
                EditorDrumInstrumentPicker(current: key.pitch) { pitch in
                    replace(key, withPitch: pitch)
                }
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                Stepper(value: rowCount, in: 1 ... 3) {
                    LabeledContent(
                        String(localized: "editor.drum.layout.rows", bundle: .module),
                        value: "\(layout.rowCount)",
                    )
                }
                Picker(String(localized: "editor.drum.layout.preset", bundle: .module), selection: preset) {
                    Text("editor.drum.layout.preset.singleVoice", bundle: .module)
                        .tag(DrumVoicePreset.singleVoice)
                    Text("editor.drum.layout.preset.handsAndFeet", bundle: .module)
                        .tag(DrumVoicePreset.handsAndFeet)
                }
            }

            Section {
                // Drag to reorder, tap a row to re-instrument it, tap its voice badge to flip 1 ↔ 2. Deleting a key
                // is a swipe, which is the gesture a `List` row already promises.
                ForEach(layout.keys) { key in
                    row(for: key)
                }
                .onMove { layout.keys.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { layout.keys.remove(atOffsets: $0) }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(role: .cancel) { dismiss() } label: {
                Text("editor.drum.layout.cancel", bundle: .module)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                apply(layout)
                dismiss()
            } label: {
                Text("editor.drum.layout.done", bundle: .module)
            }
        }
    }

    private func row(for key: DrumPadKey) -> some View {
        HStack {
            EditorDrumNoteheadGlyph(headType: key.headType)
                .frame(width: 20)
            Button {
                pickingKeyID = key.pitch
            } label: {
                Text(DrumKeyLabel.name(for: key))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button {
                toggleVoice(of: key)
            } label: {
                Text("editor.drum.layout.voiceBadge \(key.voiceIndex + 1)", bundle: .module)
                    .font(.footnote)
                    .monospacedDigit()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Editing

    private var rowCount: Binding<Int> {
        Binding(
            get: { layout.rowCount },
            set: { layout = DrumPadLayout(keys: layout.keys, rowCount: $0) },
        )
    }

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

    private var pickingKey: Binding<DrumPadKey?> {
        Binding(
            get: { layout.keys.first { $0.pitch == pickingKeyID } },
            set: { pickingKeyID = $0?.pitch },
        )
    }

    private func toggleVoice(of key: DrumPadKey) {
        guard let index = layout.keys.firstIndex(where: { $0.pitch == key.pitch }) else { return }
        layout.keys[index].voiceIndex = key.voiceIndex == 0 ? 1 : 0
    }

    /// Swaps a key's instrument in place, keeping its position and its voice — the row is a slot on the pad, and
    /// re-instrumenting it should not move it. A pitch the layout already holds is refused rather than duplicated:
    /// two keys writing the same drum would toggle each other.
    private func replace(_ key: DrumPadKey, withPitch pitch: Int) {
        pickingKeyID = nil
        guard let index = layout.keys.firstIndex(where: { $0.pitch == key.pitch }),
              !layout.keys.contains(where: { $0.pitch == pitch }),
              let replacement = DrumPadKey(gmPitch: pitch, voiceIndex: key.voiceIndex)
        else { return }
        layout.keys[index] = replacement
    }
}

/// The instrument list a key's row opens: every drum `GMDrumset` names, by pitch.
struct EditorDrumInstrumentPicker: View {
    let current: Int
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
                        if let key = DrumPadKey(gmPitch: pitch) {
                            EditorDrumNoteheadGlyph(headType: key.headType)
                                .frame(width: 20)
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
            }
            .navigationTitle(Text("editor.drum.layout.instrument", bundle: .module))
            .inlineNavigationTitleCompat()
        }
    }
}
