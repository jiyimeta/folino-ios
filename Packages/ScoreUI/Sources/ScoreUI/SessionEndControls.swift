import SwiftUI
import UtilityUI

// The look of the controls that end a session — note editing's and annotation's alike — modelled on the pair Photos
// puts either side of the display cutout: ✕ leading, which throws the session's work away, and a single trailing
// control that either commits it or offers to go back to the original.
//
// Only the LABELS live here. The buttons around them read their own feature's view model (the Editor's session, the
// Reader's ink) and decide what ✕ / ✓ / revert actually do; what they share is the drawn surface, and it is shared
// so the two strips read as the same physical thing. Features don't import each other, which is why the shape sits
// in ScoreUI rather than in either of them.

/// The band's own proportions, taken from a Photos screenshot rather than chosen: its ✕ and 元に戻す are each 26pt
/// tall and 64–66pt wide, centred in the 62pt reserved band.
///
/// The Reader owns the band itself and its horizontal inset (`ReaderTopBarLayout.cutoutTierHorizontalInset`, from the
/// same measurement). Nothing enforces the pairing; if one moves, look at the other.
public enum SessionBandMetrics {
    public static let height: CGFloat = 26
    public static let minimumWidth: CGFloat = 64
    /// Small on purpose: a 26pt pill cannot carry body text. Photos' own label measures ~13pt.
    public static let font: Font = .footnote.weight(.semibold)
    /// Glyphs sit a touch larger than the text does, or ✕ and ✓ read as specks against a word of the same weight.
    public static let glyphFont: Font = .system(size: 14, weight: .semibold)
}

extension View {
    /// Shapes a label into the band's pill: fixed height, matched minimum width, capsule-clipped so whatever surface
    /// the caller puts behind it is that pill and nothing else.
    public func sessionBandPill() -> some View {
        padding(.horizontal, 10)
            .frame(
                minWidth: SessionBandMetrics.minimumWidth,
                minHeight: SessionBandMetrics.height,
            )
            .frame(height: SessionBandMetrics.height)
            .clipShape(.capsule)
    }
}

/// ✕ — the label of the control that throws the session's work away. Glass of its own in the band; bare in the
/// control tier, where the button's caller wraps it in the row's shared glass.
public struct SessionDiscardLabel: View {
    /// `true` in the cutout tier, where the control is drawn to the band's own proportions rather than the control
    /// tier's — see `SessionBandMetrics`.
    let inCutoutBand: Bool

    public init(inCutoutBand: Bool = false) {
        self.inCutoutBand = inCutoutBand
    }

    public var body: some View {
        if inCutoutBand {
            Image(systemName: "xmark")
                .font(SessionBandMetrics.glyphFont)
                .sessionBandPill()
                .interactiveGlassCompat()
        } else {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
        }
    }
}

/// What the trailing control is showing — three controls wearing one slot. Which one is showing is the whole status
/// readout for the session, so a feature derives it, never sets it:
///
/// * `commitUnchanged` — **nothing has ever been changed**: a checkmark on plain glass. Leaving changes nothing, so
///   it is quiet.
/// * `revert` — **the content differs from the original, but not because of this session**: revert, on red. The
///   only thing worth offering is undoing the *previous* work, and it is destructive, so it is the one coloured
///   control in the strip.
/// * `commitEdited` — **this session has changed something**: a checkmark on yellow. Committing is now a real act
///   with a real result, and the colour says the content is not what it was when you opened it.
///
/// The session's own changes win over the revert offer deliberately: while you are mid-session, the thing you want
/// is to keep or drop what you just did, not to be offered a rollback of everything.
public enum SessionEndControlStyle: Sendable {
    case commitUnchanged
    case commitEdited
    case revert
}

/// The trailing control's label. The red and the yellow are carried BY the glass (`tintedGlassCompat`), not painted
/// as a flat fill behind it, so a coloured state belongs to the same family of surfaces as the uncoloured one — the
/// control changes colour, not material. It is also the control's single surface: an earlier version put a glass
/// pill around the button and a smaller filled capsule inside it, which read as two stacked controls.
public struct SessionEndControlLabel: View {
    let style: SessionEndControlStyle
    let inCutoutBand: Bool

    public init(style: SessionEndControlStyle, inCutoutBand: Bool = false) {
        self.style = style
        self.inCutoutBand = inCutoutBand
    }

    public var body: some View {
        switch style {
        case .commitUnchanged:
            checkmark
                .interactiveGlassCompat()
        case .commitEdited:
            checkmark
                .foregroundStyle(.black)
                .tintedGlassCompat(.yellow, in: .capsule)
        case .revert:
            revertLabel
        }
    }

    @ViewBuilder
    private var checkmark: some View {
        if inCutoutBand {
            Image(systemName: "checkmark")
                .font(SessionBandMetrics.glyphFont)
                .sessionBandPill()
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
        }
    }

    @ViewBuilder
    private var revertLabel: some View {
        if inCutoutBand {
            Text("sessionEnd.revert.short", bundle: .module)
                .font(SessionBandMetrics.font)
                .foregroundStyle(.white)
                .sessionBandPill()
                .tintedGlassCompat(.red, in: .capsule)
        } else {
            Text("sessionEnd.revert.short", bundle: .module)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .tintedGlassCompat(.red, in: .capsule)
        }
    }
}

#if DEBUG
// The shape a cutout-tier band mounts: ✕ leading, the session-end control trailing, nothing in between — the
// cutout's width varies by model and neither label may assume how much room the middle has.
//
// The frame reproduces the real band so this preview can be measured against the Photos screenshot it was matched
// to: 45pt inset each side (`ReaderTopBarLayout.cutoutTierHorizontalInset`), 62pt tall, which is an iPhone 16 Pro's
// top safe area. Photos' own controls land at x 44…110 and x 293…357 on a 402pt-wide screen.
#Preview("Cutout tier · all three states") {
    VStack(spacing: 0) {
        band(style: .commitUnchanged)
        band(style: .revert)
        band(style: .commitEdited)
    }
    .background(Color(white: 0.97))
}

#Preview("Control tier · all three states") {
    VStack(spacing: 12) {
        row(style: .commitUnchanged)
        row(style: .revert)
        row(style: .commitEdited)
    }
    .padding()
    .background(Color(white: 0.97))
}

@MainActor
private func band(style: SessionEndControlStyle) -> some View {
    HStack {
        SessionDiscardLabel(inCutoutBand: true)
        Spacer(minLength: 0)
        SessionEndControlLabel(style: style, inCutoutBand: true)
    }
    .padding(.horizontal, 45)
    .frame(maxWidth: .infinity)
    .frame(height: 62)
}

@MainActor
private func row(style: SessionEndControlStyle) -> some View {
    HStack(spacing: 12) {
        SessionDiscardLabel()
            .interactiveGlassCompat()
        Spacer(minLength: 0)
        SessionEndControlLabel(style: style)
    }
}
#endif
