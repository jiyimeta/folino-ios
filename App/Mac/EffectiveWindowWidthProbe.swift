import AppKit

/// Effective app-window width in points at emission time, for the launch `score_prefs` analytics snapshot (see
/// `AppBootstrap+AnalyticsSnapshot.swift`). Mac counterpart of the iOS `EffectiveWindowWidthProbe` in `App/iOS` —
/// same measurement, `NSScreen` in place of `UIWindowScene`.
@MainActor
enum EffectiveWindowWidthProbe {
    /// Prefers the key window (what the user is actually resizing), falling back to the main window, then any
    /// window, then the main screen's width before any window exists — a width of 0 buckets to the smallest
    /// breakpoint, an acceptable degenerate case for a headless launch.
    ///
    /// Reads `contentView`'s width, not the window's own `frame.width` — the window frame includes title-bar and
    /// border chrome the iOS counterpart's `window.bounds.width` (a content-relative measurement) does not, and a
    /// paired probe has to report the same quantity or the pairing is a lie the day this reaches real analytics.
    static func pt() -> Double {
        let window = NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first
        if let contentWidth = window?.contentView?.frame.width {
            return contentWidth
        }
        return Double(NSScreen.main?.frame.width ?? 0)
    }
}
