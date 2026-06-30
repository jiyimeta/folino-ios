import CoreGraphics
import Domain
import SheetMusicPDF

/// `PDFPlaybackGeometry` backed by swift-sheet-music's `PDFScoreGeometry`. Bridges ssm's y-up (PDF
/// user space, origin bottom-left) coordinates to the Reader's top-left mediaBox space, so the Reader
/// can place a cursor / resolve taps without importing the ssm PDF module.
struct SheetMusicPDFPlaybackGeometry: PDFPlaybackGeometry {
    private let inner: PDFScoreGeometry

    init(_ inner: PDFScoreGeometry) {
        self.inner = inner
    }

    var pageSizes: [Int: CGSize] {
        inner.pageSizes
    }

    func cursorRect(for cursor: ScoreCursor, in score: Score) -> PDFCursorRect? {
        guard let rect = inner.cursorRect(for: cursor, in: score) else { return nil }
        let pageHeight = inner.pageSizes[rect.pageIndex]?.height ?? 0
        let flipped = rect.flipped(pageHeight: pageHeight)
        return PDFCursorRect(pageIndex: flipped.pageIndex, rect: flipped.rect)
    }

    func cursor(at point: CGPoint, pageIndex: Int) -> ScoreCursor? {
        // The reader hands a top-left point; ssm hit-tests in y-up page space.
        let pageHeight = inner.pageSizes[pageIndex]?.height ?? 0
        let yUp = CGPoint(x: point.x, y: pageHeight - point.y)
        guard let item = inner.hitTest(pageIndex: pageIndex, point: yUp) else { return nil }
        return .item(item)
    }
}
