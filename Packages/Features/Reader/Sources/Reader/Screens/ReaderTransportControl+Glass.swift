import SwiftUI
import UtilityUI

/// The transport card's background. Split out of `ReaderTransportControl.swift` to keep that file under SwiftLint's
/// file-length limit.
extension ReaderTransportControl {
    /// Floor for the bottom corner radius, so square-cornered devices (e.g. iPhone SE, iPad) still get a rounded card.
    static let minCardCornerRadius: CGFloat = 14
    /// Fixed radius for the card's free top corners — a smaller, constant value than the device-hugging bottom corners
    /// (Apple's medium-detent sheet pattern, matching VocalTuner).
    static let topCornerRadius: CGFloat = 18

    /// Bottom corner radius that nests the card concentrically inside the device's screen corners: `deviceCorner -
    /// margin`, floored at `minCardCornerRadius` for square-cornered devices.
    var bottomCornerRadius: CGFloat {
        max(DeviceMetrics.screenCornerRadius - TransportCardMetrics.cardMargin, Self.minCardCornerRadius)
    }

    /// The card's glass: two layers crossfading inside the *same* animating frame, rather than one material morphing
    /// into the other. The expanded card's non-interactive glass bleeds into the bottom safe area behind uneven,
    /// device-hugging corners; the pill is an interactive glass capsule. Neither can be expressed as the other, so
    /// each end state keeps exactly the look it always had and the card's size carries the motion.
    ///
    /// The crossfade rides the same interpolated `morph` that resizes the card (rather than a transaction-animated
    /// opacity flip), so the fade can never desync from the resize — and each layer is mounted only while it is
    /// visible at all, so a settled card carries exactly ONE live glass effect. Glass samples the content behind it
    /// every frame it exists; paying that for a second, fully transparent layer made every drag of the settled card
    /// more expensive than it had to be.
    func cardBackground(_ metrics: TransportCardMetrics) -> some View {
        ZStack {
            if metrics.showsExpandedGlass {
                expandedCardGlass
                    .opacity(metrics.expandedGlassOpacity)
            }
            if metrics.showsCompactGlass {
                Capsule()
                    .fill(.clear)
                    .interactiveGlassCompat(in: Capsule())
                    .opacity(metrics.compactGlassOpacity)
            }
        }
    }

    /// The glass invades the bottom safe area (`.ignoresSafeArea`) but its own `.padding(.bottom, cardMargin)` keeps
    /// the rounded rect `cardMargin` clear of the physical edge, nesting it concentrically inside the device corners.
    /// The free top corners use a smaller fixed radius. The foreground content is unaffected by `.ignoresSafeArea`, so
    /// it stays above the home indicator.
    private var expandedCardGlass: some View {
        let bottom = bottomCornerRadius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: min(Self.topCornerRadius, bottom),
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: min(Self.topCornerRadius, bottom),
            style: .continuous,
        )
        return shape
            .fill(.clear)
            .regularGlassCompat(in: shape)
            .padding(.bottom, TransportCardMetrics.cardMargin)
            .ignoresSafeArea(.container, edges: .bottom)
    }
}
