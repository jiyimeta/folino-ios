import Foundation

/// A rectangle on one page of the original imported PDF, expressed in that page's TOP-LEFT-origin
/// coordinate space (mediaBox points, y growing downward). Produced by `PDFPlaybackGeometry` so the
/// Reader can draw a playback cursor on the displayed PDF, or place other on-PDF overlays, without
/// importing swift-sheet-music's PDF module.
public struct PDFCursorRect: Hashable, Sendable {
    public let pageIndex: Int
    /// Top-left-origin rect in the page's mediaBox points, ready to project into the Reader's
    /// page-frame coordinate space.
    public let rect: CGRect

    public init(pageIndex: Int, rect: CGRect) {
        self.pageIndex = pageIndex
        self.rect = rect
    }
}
