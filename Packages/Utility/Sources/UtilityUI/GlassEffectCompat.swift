import SwiftUI

/// Availability-guarded substitutes for the iOS/macOS 26 Liquid Glass APIs. Each helper applies the real glass
/// treatment on iOS 26+ / macOS 26+ and a frosted `.regularMaterial` fallback below that, so call sites stay
/// one-liners instead of inline `#available` ladders. The 26-only symbols (`Glass`, `.glassProminent`) appear only
/// inside the `if #available(iOS 26, macOS 26, *)` branches, which keeps this file compiling at the iOS 18 / macOS 15
/// deployment floors. `macOS 26` has to be spelled out explicitly here — `#available(iOS 26, *)` alone treats every
/// non-iOS platform as unconditionally available, which would call the macOS-26-only glass APIs on macOS 15.
extension View {
    /// `.glassEffect(.regular.interactive())` on iOS 26+ / macOS 26+; a `.regularMaterial` capsule background below
    /// that. The fallback shape is `Capsule()` because that is `glassEffect`'s default shape.
    @ViewBuilder
    public func interactiveGlassCompat() -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular.interactive())
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }

    /// `.glassEffect(.regular.interactive(), in: shape)` on iOS 26+ / macOS 26+; a `.regularMaterial` background
    /// drawn in the same shape below that.
    @ViewBuilder
    public func interactiveGlassCompat<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// `.glassEffect(.regular.tint(_).interactive(), in: shape)` on iOS 26+ / macOS 26+ — glass that carries a
    /// colour rather than a flat fill of it, the way the system tints a prominent glass control.
    ///
    /// Below that floor there is no glass to tint, so the shape is filled with the colour outright: a
    /// `.regularMaterial` under a strong tint reads as muddy, and the point of tinting this control is that it is
    /// unmistakable.
    @ViewBuilder
    public func tintedGlassCompat<S: Shape>(_ tint: Color, in shape: S) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            background(tint, in: shape)
        }
    }

    /// `.glassEffect(.regular, in: shape)` (non-interactive) on iOS 26+ / macOS 26+; a `.regularMaterial` background
    /// drawn in the same shape below that.
    @ViewBuilder
    public func regularGlassCompat<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// `.buttonStyle(.glassProminent)` on iOS 26+ / macOS 26+; `.buttonStyle(.borderedProminent)` below that — the
    /// closest pre-glass prominent treatment.
    @ViewBuilder
    public func glassProminentButtonStyleCompat() -> some View {
        if #available(iOS 26, macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 24) {
        Image(systemName: "chevron.backward")
            .font(.system(size: 20, weight: .medium))
            .frame(width: 44, height: 44)
            .interactiveGlassCompat()

        HStack(spacing: 0) {
            Text(verbatim: "A").frame(width: 44, height: 44)
            Text(verbatim: "B").frame(width: 44, height: 44)
        }
        .interactiveGlassCompat(in: .capsule)

        Text(verbatim: "Seek card")
            .frame(width: 220, height: 80)
            .regularGlassCompat(in: .rect(cornerRadius: 18))

        Button {} label: { Image(systemName: "checkmark") }
            .glassProminentButtonStyleCompat()
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
        LinearGradient(
            colors: [.blue.opacity(0.4), .orange.opacity(0.4)],
            startPoint: .top,
            endPoint: .bottom,
        )
        .ignoresSafeArea()
    }
}
#endif
