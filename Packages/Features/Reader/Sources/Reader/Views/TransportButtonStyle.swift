import SwiftUI

/// Press feedback for the transport's icon buttons — a brief scale-up + dim on touch-down. Tuned to match the
/// per-staff toggles (`CircleBorderedToggleButtonStyle`) so the control clusters feel consistent: scale `1.16`,
/// opacity `0.7`, `.snappy(duration: 0.27)`. Only the press transition is animated — transport buttons have no
/// persistent on/off state. Color is left to the surrounding `.tint(...)` so the glyph keeps its existing fill.
///
/// Ported from VocalTuner so the two apps' transports feel identical.
struct TransportButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.16 : 1)
            // Dim to a greyed-out look when disabled (e.g. the next-score button on the last playlist score); otherwise
            // the brief press-dim.
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.3)
            .animation(.snappy(duration: 0.27), value: configuration.isPressed)
    }
}
