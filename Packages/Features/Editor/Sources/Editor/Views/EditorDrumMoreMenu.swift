import EditorCore
import SwiftUI

/// The `⋯` key that closes the drum pad's last row: everything General MIDI names that the pad itself does not
/// show, as a checklist of what is in the caret's column.
///
/// The pad holds fourteen instruments and GM names twenty-seven, and the layout is deliberately global — it does
/// not grow itself from the open file (`DrumPadLayout`). Without this key a splash cymbal in an imported chart
/// would be invisible: it could not light, and there would be no key to press to take it away. So the menu is not a
/// shortcut, it is the rest of the kit.
///
/// A row toggles its instrument in the caret's column exactly as pressing a key does. It does NOT add the
/// instrument to the pad — what the pad shows is a separate decision, and the layout sheet at the bottom of the
/// menu is where it is made.
struct EditorDrumMoreMenu: View {
    let layout: DrumPadLayout
    let litPitches: Set<Int>
    let isFlexible: Bool
    let press: (DrumPadKey) -> Void
    let editLayout: () -> Void

    var body: some View {
        Menu {
            // `Toggle`, not a `Label` with a conditional checkmark: inside a menu UIKit draws and aligns the
            // checkmark itself, so the rows stay flush whether or not they are on.
            ForEach(hidden) { key in
                Toggle(isOn: Binding(get: { litPitches.contains(key.pitch) }, set: { _ in press(key) })) {
                    Text(DrumKeyLabel.name(for: key))
                }
            }
            Divider()
            Button(action: editLayout) {
                Label {
                    Text("editor.drum.layout.edit", bundle: .module)
                } icon: {
                    Image(systemName: "square.grid.3x2")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                // The same armed capsule a key wears, for the same reason: something in this column is sounding.
                // Without it the one instrument the pad cannot show would be the one instrument with no feedback.
                .padKeyChrome(isArmed: isAnyHiddenLit, isFlexible: isFlexible)
        }
        .accessibilityLabel(Text("editor.pad.drum.more", bundle: .module))
        .accessibilityAddTraits(isAnyHiddenLit ? [.isSelected] : [])
    }

    /// Every GM drum the layout leaves off, in pitch order — which is roughly kit order, low to high.
    private var hidden: [DrumPadKey] {
        let shown = Set(layout.keys.map(\.pitch))
        return DrumPadKey.allGMPitches
            .filter { !shown.contains($0) }
            .compactMap { DrumPadKey(gmPitch: $0) }
    }

    private var isAnyHiddenLit: Bool {
        let shown = Set(layout.keys.map(\.pitch))
        return litPitches.contains { !shown.contains($0) }
    }
}
