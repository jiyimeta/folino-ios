import ScreenshotKit
import SwiftUI

enum FolinoScreenshotLayout {
    /// folino.icon canvas gradient: white -> light blue, vertical (y 0 -> 0.7).
    static let background = LinearGradient(
        stops: [
            .init(color: .white, location: 0),
            .init(color: Color(.sRGB, red: 0.807, green: 0.884, blue: 1.0), location: 0.7),
        ],
        startPoint: .top,
        endPoint: .bottom,
    )

    /// - Parameter innerStatusBarHeight: override for the height of the thumbnail's inner status-bar band. Pass `nil`
    ///   (the default) to keep ScreenshotKit's per-idiom defaults (50pt iPhone / 28pt iPad) so existing scenes are
    ///   unchanged. PiPScene passes `0` so its own faux 9:41 row owns the full thumbnail from the very top.
    static func layout(
        for idiom: ScreenshotIdiom,
        subtitleBullet: Bool = false,
        innerStatusBarColor: Color = .white,
        innerStatusBarHeight: CGFloat? = nil,
    ) -> ScreenshotLayout {
        // titleCenterYFraction is left at the ScreenshotKit defaults (0.05 iPhone /
        // 0.06 iPad) to match VocalTuner. The earlier clipping was an artifact of
        // the device-framed preview (notch); the actual capture is a plain rectangle.
        switch idiom {
        case .iPhone:
            .standard(
                titleColor: .black,
                subtitleColor: .black.opacity(0.85),
                subtitleBullet: subtitleBullet,
                thumbnailCornerRadius: 36,
                innerStatusBarHeight: innerStatusBarHeight ?? 50,
                innerStatusBarColor: innerStatusBarColor,
                background: background,
            )
        case .iPad:
            .iPad(
                titleColor: .black,
                subtitleColor: .black.opacity(0.85),
                subtitleBullet: subtitleBullet,
                thumbnailCornerRadius: 28,
                innerStatusBarHeight: innerStatusBarHeight ?? 28,
                innerStatusBarColor: innerStatusBarColor,
                background: background,
            )
        }
    }

    /// ScreenshotKit's per-idiom band height, restated so a scene can draw that space itself — see
    /// `readerStatusBarBand(for:)`.
    static func statusBarHeight(for idiom: ScreenshotIdiom) -> CGFloat {
        idiom.pick(iPhone: 50, iPad: 28)
    }
}

extension View {
    /// Draw the faux status-bar band for a Reader-backed scene as the *continuation* of the toolbar's shadow, so the
    /// white score page reads as one surface. Pair with `innerStatusBarHeight: 0` so this is the only band drawn.
    ///
    /// A real phone gives the app a ~59pt top safe area, so the toolbar's glass pills sit well clear of the screen
    /// edge and the soft shadow they cast upwards fades out inside the app's own bounds. A scene has no safe area:
    /// the pills land against the top of the app UI, and both `NavigationStack` and `TrueScaleInner` clip there — so
    /// the shadow stops dead on that line. With ScreenshotKit's flat white `innerStatusBarColor` above it, the page
    /// steps 255 -> 251 across the full width of the card and reads as a lighter strip.
    ///
    /// Neither half of the clip can be lifted: padding the nav container just moves the line down, and
    /// `safeAreaInset` insets the content under the toolbar while leaving the toolbar itself pinned. So the band
    /// picks the shadow back up instead. The iPad's 28pt band is far enough from its pills that nothing bleeds into
    /// it — it stays flat white, which `shadowEdge: 1` gives for free.
    ///
    /// - Parameter shadowEdge: white level the app paints at its own top edge, sampled from a capture.
    func readerStatusBarBand(
        for idiom: ScreenshotIdiom,
        shadowEdge: Double = 0.982,
    ) -> some View {
        let edge = Color(white: idiom.pick(iPhone: shadowEdge, iPad: 1))
        return VStack(spacing: 0) {
            LinearGradient(colors: [.white, edge], startPoint: .top, endPoint: .bottom)
                .frame(height: FolinoScreenshotLayout.statusBarHeight(for: idiom))
            self
        }
        // The band's height lands on a fractional pixel once the thumbnail is scaled, and the seam row between the
        // two children then shows the marketing gradient through as a blue hairline. Back the stack with the band's
        // own edge colour so that row blends into the join instead.
        .background(edge)
    }
}
