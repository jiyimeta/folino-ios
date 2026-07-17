import SwiftUI

/// Shared press feedback for every key on `EditorPadView`'s bottom pad: a brief scale-up + dim on touch-down, mirrored
/// from the Reader transport's `TransportButtonStyle` (scale `1.12`, dim to `0.7`, `.snappy(duration: 0.27)`) so the
/// pad's touch feel matches the rest of the chrome. Duration keys additionally pass `isArmed: true` for the key whose
/// duration matches `EditorViewModel.armedDuration`, drawing a persistent accent capsule behind the glyph — independent
/// of press state — so the armed duration reads at a glance.
struct PadKeyStyle: ButtonStyle {
    var isArmed = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 40, minHeight: 44)
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
    /// Duration key glyph — Unicode musical note symbols (U+1D15D…U+1D164 family) rendered through the system's font
    /// fallback. Acceptable v1 stand-ins for the spec's "crisp custom glyphs"; a custom SF Symbol pass is a follow-up
    /// listed in the final checklist.
    static func duration(_ symbol: String) -> some View {
        Text(verbatim: symbol)
            .font(.system(size: 22))
    }

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
