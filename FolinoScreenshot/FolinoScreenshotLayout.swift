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
}
