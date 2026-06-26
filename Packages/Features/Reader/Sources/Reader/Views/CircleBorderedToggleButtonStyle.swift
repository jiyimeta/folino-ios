import SwiftUI

/// A circular on/off toggle button: a 28pt accent-filled circle (white glyph) when on, a quiet grey circle (accent
/// glyph) when off, dimmed when disabled. Press feedback is a brief scale-up + dim. Used for the per-staff
/// solo / mute / visibility toggles so they read as a consistent control cluster.
///
/// Ported from VocalTuner's mixer toggle so the two apps' staff controls match.
struct CircleBorderedToggleButtonStyle: ButtonStyle {
    let isOn: Bool

    @Environment(\.isEnabled) private var isEnabled

    private var foregroundColor: Color {
        switch (isOn, isEnabled) {
        case (true, true): .white
        case (false, true): .accentColor
        case (_, false): .secondary.opacity(0.4)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundStyle(foregroundColor)
            .frame(width: 28, height: 28)
            .background(isOn && isEnabled ? Color.accentColor : .secondary.opacity(0.22), in: .circle)
            .scaleEffect(configuration.isPressed ? 1.16 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.snappy(duration: 0.27), value: configuration.isPressed)
            .animation(.snappy(duration: 0.27), value: isOn)
    }
}
