import CoreGraphics
import SheetMusicCore

/// Maps a parsed PDF score's musical positions back to geometry on the ORIGINAL imported PDF, so the
/// Reader can draw a playback cursor on the displayed PDF and resolve taps to seek targets. The
/// concrete implementation wraps swift-sheet-music's `PDFScoreGeometry` in Infrastructure; the Reader
/// only ever sees this protocol — Features must not import the ssm PDF module.
///
/// All rects and points are in each page's TOP-LEFT-origin mediaBox space (y down), matching how the
/// Reader lays out PDF pages. The adapter flips ssm's y-up coordinates before they cross this seam.
public protocol PDFPlaybackGeometry: Sendable {
    /// MediaBox size of each page, indexed by page index. Used to clamp and to project rects into the
    /// reader's page-frame space.
    var pageSizes: [Int: CGSize] { get }

    /// Full-height cursor bar for `cursor` on its page, or `nil` when the column can't be located
    /// (e.g. a stale cursor against a different score).
    func cursorRect(for cursor: ScoreCursor, in score: Score) -> PDFCursorRect?

    /// Resolve a tap at `point` (top-left mediaBox coords) on `pageIndex` to a seek target, or `nil`
    /// when nothing musical is near the tap.
    func cursor(at point: CGPoint, pageIndex: Int) -> ScoreCursor?
}
