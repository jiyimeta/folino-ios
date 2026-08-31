import AppKit

/// Effective app-window width in points at emission time, for the launch `score_prefs` analytics snapshot (see
/// `AppBootstrap+AnalyticsSnapshot.swift`). Mac counterpart of the iOS `EffectiveWindowWidthProbe` in `App/iOS` —
/// same measurement, `NSScreen` in place of `UIWindowScene`.
@MainActor
enum EffectiveWindowWidthProbe {
    /// Prefers the key window (what the user is actually resizing), falling back to the main window, then any
    /// window, then the main screen's width before any window exists — a width of 0 buckets to the smallest
    /// breakpoint, an acceptable degenerate case for a headless launch.
    static func pt() -> Double {
        let window = NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first
        if let window {
            return window.frame.width
        }
        return Double(NSScreen.main?.frame.width ?? 0)
    }
}
