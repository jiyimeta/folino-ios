import SwiftUI

/// The popover body for `ClefMenu`: a grid of SMuFL clef tiles grouped by family plus an optional reset row. Takes only
/// the narrow inputs it needs — the current raw clef type, whether a reset is available — and surfaces user intent back
/// through the `onSelect` / `onReset` closures so it stays free of the `LayoutSettingsModel` and `isPresented` state.
struct ClefPopoverContent: View {
    let currentRawType: String
    let canReset: Bool
    let onSelect: (ClefMenuChoice) -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Percussion staves stay on percussion clefs; pitched staves stay on pitched clefs. Mixing the two would
            // produce nonsensical engraving (a kick drum line under a treble G, or a melody under `||`), so the picker
            // hides the family the staff doesn't belong to.
            if isPercussionStaff(rawType: currentRawType) {
                tileRow(ClefMenuChoice.percussionFamily, current: currentRawType)
            } else {
                tileRow(ClefMenuChoice.trebleFamily, current: currentRawType)
                Divider()
                tileRow(ClefMenuChoice.bassFamily, current: currentRawType)
                Divider()
                tileRow(ClefMenuChoice.cFamily, current: currentRawType)
            }
            if canReset {
                Divider()
                resetButton
                    .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 16)
        // Cap the popover width so the 5-tile treble row scrolls horizontally, giving the surrounding padding room to
        // breathe on small devices.
        .frame(width: 260)
    }

    private func isPercussionStaff(rawType: String) -> Bool {
        ClefMenuChoice.from(rawType: rawType)?.isPercussion ?? false
    }

    private var resetButton: some View {
        Button {
            onReset()
        } label: {
            Text("reader.preferences.clef.resetDefault", bundle: .module)
                .font(.callout)
                .foregroundStyle(.tint)
        }
    }

    private func tileRow(_ choices: [ClefMenuChoice], current: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(choices, id: \.self) { choice in
                    ClefTile(choice: choice, current: current, onSelect: onSelect)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}
