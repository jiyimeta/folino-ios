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

    static func layout(for idiom: ScreenshotIdiom, subtitleBullet: Bool = false) -> ScreenshotLayout {
        switch idiom {
        case .iPhone:
            .standard(
                titleCenterYFraction: 0.12,
                titleColor: .black,
                subtitleColor: .black.opacity(0.85),
                subtitleBullet: subtitleBullet,
                background: background,
            )
        case .iPad:
            .iPad(
                titleCenterYFraction: 0.12,
                titleColor: .black,
                subtitleColor: .black.opacity(0.85),
                subtitleBullet: subtitleBullet,
                background: background,
            )
        }
    }
}
