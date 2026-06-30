import SwiftUI

/// Shared styling for the on-PDF playback cursor drawn over the original PDF in both reading modes.
enum PDFPlaybackCursor {
    /// Translucent accent fill spanning the cursor's system-height column. Lighter than the score reader's
    /// on-staff highlight so the original PDF engraving stays legible under the bar.
    static let color = Color.accentColor.opacity(0.3)
}
