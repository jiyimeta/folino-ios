import SwiftUI

/// Shared press feedback for every key on `EditorPadView`'s bottom pad: a brief scale-up + dim on touch-down, mirrored
/// from the Reader transport's `TransportButtonStyle` (scale `1.12`, dim to `0.7`, `.snappy(duration: 0.27)`) so the
/// pad's touch feel matches the rest of the chrome. Duration keys additionally pass `isArmed: true` for the key whose
/// duration matches `EditorViewModel.armedDuration`, drawing a persistent accent capsule behind the glyph — independent
/// of press state — so the armed duration reads at a glance.
struct PadKeyStyle: ButtonStyle {
    var isArmed = false
    /// Compact rows pack ten keys across (C–B, ▴▾, delete). A fixed 40 pt minimum made that row wider than any
    /// iPhone, so those keys instead share the row's width — `maxWidth: .infinity` can't overflow, and the 44 pt
    /// height keeps each key comfortably tappable. The iPad row has the room, so it keeps the fixed minimum.
    var isFlexible = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: isFlexible ? .infinity : nil)
            .frame(minWidth: isFlexible ? nil : 40, minHeight: 44)
            .contentShape(Rectangle())
            .background {
                if isArmed {
                    Capsule().fill(Color.accentColor.opacity(0.25))
                }
            }
            .scaleEffect(configuration.isPressed ? 1.12 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.snappy(duration: 0.27), value: configuration.isPressed)
    }
}

/// Glyph builders shared by the pad's keys, kept in one place so every key group's font/weight stays in sync.
enum PadKeyGlyph {
    /// Duration key glyph — a SMuFL note drawn with the score's own Bravura font (see `PadDurationGlyph`, which owns
    /// the codepoints and the family name). Bravura's note glyphs sit on the baseline with the stem rising above it,
    /// so the whole row lines up on its noteheads; 20 pt keeps the tallest (64th, stem + four flags) inside the
    /// 44 pt key.
    static func duration(_ symbol: String) -> some View {
        Text(verbatim: symbol)
            .font(PadDurationGlyph.swiftUIFont(size: durationSize))
            // Cut the music font's enormous ascent/descent off the line box — see `PadDurationGlyph.lineTrim`.
            .padding(.top, -durationTrim.top)
            .padding(.bottom, -durationTrim.bottom)
    }

    private static let durationSize: CGFloat = 20
    private static let durationTrim = PadDurationGlyph.lineTrim(size: durationSize)

    /// Pitch-letter key glyph (C…B).
    static func pitchLetter(_ letter: Character) -> some View {
        Text(verbatim: String(letter))
            .font(.system(size: 17, weight: .semibold, design: .rounded))
    }

    /// SF Symbol glyph for the octave-step and delete keys — matches the Reader overlay's 20pt medium icon size.
    static func symbol(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 20, weight: .medium))
    }
}
