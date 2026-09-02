import SwiftUI

extension Color {
    /// `Color(.systemBackground)` on iOS; the closest macOS analogue (`NSColor.windowBackgroundColor`) on macOS.
    /// Exists so a call site that needs the platform's default opaque surface color doesn't have to embed `#if
    /// os(iOS)` inline, which SwiftFormat's `--ifdef no-indent` fights when it lands inside a SwiftUI modifier chain.
    public static var systemBackgroundCompat: Color {
        #if os(iOS)
        Color(.systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}
