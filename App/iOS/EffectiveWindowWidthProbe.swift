import UIKit

/// Effective app-window width in points at emission time, for the launch `score_prefs` analytics snapshot (see
/// `AppBootstrap+AnalyticsSnapshot.swift`). Split out into a paired iOS/Mac type because the underlying measurement
/// is UIKit-only.
@MainActor
enum EffectiveWindowWidthProbe {
    /// Split View / Stage Manager narrow the window below the screen width, which is exactly the layout-relevant
    /// fact. Falls back to the screen bounds before a key window exists; a width of 0 buckets to the smallest
    /// breakpoint, an acceptable degenerate case for a headless launch.
    ///
    /// The foreground scene is chosen deliberately: `connectedScenes` is a `Set`, so with two folino windows open its
    /// iteration order is arbitrary and unstable across launches — taking any scene could measure the background
    /// window. `screen_width_pt` is the axis every other `score_prefs` param is read against, so a wrong bucket here
    /// silently mis-reads the whole row.
    static func pt() -> Double {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        if let window {
            return window.bounds.width
        }
        return Double(scene?.screen.bounds.width ?? 0)
    }
}
