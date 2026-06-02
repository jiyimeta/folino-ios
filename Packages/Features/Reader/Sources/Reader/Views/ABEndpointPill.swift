import SwiftUI

/// The A and B repeat-endpoint buttons sharing a single capsule. Each half is tinted accent until its endpoint is set,
/// so when only one is set the pill reads as accent on exactly one half, split down the middle.
///
/// `flat` drops the interactive liquid-glass treatment (and its shadow) for the expanded seek card, where the pill sits
/// on the card's own glass and a raised glass-on-glass would read as heavy; it falls back to a quiet material capsule.
/// The collapsed pill keeps the interactive glass + shadow so it matches the floating transport pill beside it.
struct ABEndpointPill: View {
    let aSet: Bool
    let bSet: Bool
    let flat: Bool
    let onSetA: () -> Void
    let onSetB: () -> Void

    var body: some View {
        let pill = HStack(spacing: 0) {
            half(label: "A", action: onSetA)
            half(label: "B", action: onSetB)
        }
        .background {
            // Accent fill on the unset half (or both), split exactly at the center and clipped to the capsule so the
            // pill ends stay rounded.
            HStack(spacing: 0) {
                Rectangle().fill(aSet ? Color.clear : Color.accentColor)
                Rectangle().fill(bSet ? Color.clear : Color.accentColor)
            }
            .clipShape(.capsule)
        }

        if flat {
            pill.background(.quaternary, in: .capsule)
        } else {
            pill
                .glassEffect(.regular.interactive(), in: .capsule)
                .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
        }
    }

    private func half(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .tint(.primary)
    }
}
