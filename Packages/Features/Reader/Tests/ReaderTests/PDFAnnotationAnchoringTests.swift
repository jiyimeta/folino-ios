import CoreGraphics
import Domain
import PencilKit
@testable import Reader
import Testing

struct PDFAnnotationAnchoringTests {
    /// Two stacked pages, 100 wide, heights 140 and 120, 8pt gap.
    private let frames = [
        CGRect(x: 0, y: 0, width: 100, height: 140),
        CGRect(x: 0, y: 148, width: 100, height: 120),
    ]

    @Test func `picks page containing centroid`() {
        #expect(PDFAnnotationAnchoring.pageIndex(forCentroid: CGPoint(x: 50, y: 70), pageFrames: frames) == 0)
        #expect(PDFAnnotationAnchoring.pageIndex(forCentroid: CGPoint(x: 50, y: 200), pageFrames: frames) == 1)
    }

    @Test func `picks nearest page when in gap`() {
        // y = 144 is in the 8pt gap (140…148); closer to page 0's center (70) vs page 1's (208) -> page 0.
        #expect(PDFAnnotationAnchoring.pageIndex(forCentroid: CGPoint(x: 50, y: 144), pageFrames: frames) == 0)
    }

    @Test func `nil for empty frames`() {
        #expect(PDFAnnotationAnchoring.pageIndex(forCentroid: .zero, pageFrames: []) == nil)
    }

    @Test func `normalize then display is identity at same frame`() throws {
        let frame = frames[1]
        let n = try #require(PDFAnnotationAnchoring.normalizeTransform(pageFrame: frame))
        let d = try #require(PDFAnnotationAnchoring.displayTransform(pageFrame: frame))
        let p = CGPoint(x: 30, y: 180)
        let round = p.applying(n).applying(d)
        #expect(abs(round.x - p.x) < 0.0001)
        #expect(abs(round.y - p.y) < 0.0001)
    }

    @Test func `normalized center maps to center across zoom`() throws {
        // Capture a page-1 center at one zoom, display at a wider frame: center -> center.
        let capture = CGRect(x: 0, y: 148, width: 100, height: 120)
        let display = CGRect(x: 0, y: 300, width: 200, height: 240) // 2x wider, repositioned
        let n = try #require(PDFAnnotationAnchoring.normalizeTransform(pageFrame: capture))
        let d = try #require(PDFAnnotationAnchoring.displayTransform(pageFrame: display))
        let captureCenter = CGPoint(x: capture.midX, y: capture.midY)
        let displayed = captureCenter.applying(n).applying(d)
        #expect(abs(displayed.x - display.midX) < 0.0001)
        #expect(abs(displayed.y - display.midY) < 0.0001)
    }

    @Test func `nil transform for zero width`() {
        #expect(PDFAnnotationAnchoring.normalizeTransform(pageFrame: CGRect(x: 0, y: 0, width: 0, height: 10)) == nil)
    }

    @Test func `partitionByPage splits by page index`() {
        let a0 = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: Data())
        let a1 = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 1)), encodedDrawing: Data())
        let split = PDFAnnotationAnchoring.partitionByPage([a0, a1], pageIndex: 1)
        #expect(split.onPage.count == 1)
        #expect(split.offPage.count == 1)
    }

    @Test func `capturePage then displayPage round-trips at the same frame`() throws {
        let frame = CGRect(x: 30, y: 50, width: 200, height: 260) // a centered fitted-page rect in band space
        let point = CGPoint(x: frame.midX + 10, y: frame.midY - 20)
        let stroke = PaintTestSupport.dot(at: point)
        let captured = PDFAnnotationAnchoring.capturePage(strokes: [stroke], pageIndex: 3, pageFrame: frame)
        #expect(captured.count == 1)
        if case let .page(anchor) = try #require(captured.first).kind {
            #expect(anchor.pageIndex == 3)
        } else { Issue.record("expected .page anchor") }
        let shown = PDFAnnotationAnchoring.displayPage(captured, pageIndex: 3, pageFrame: frame)
        let out = try #require(shown.strokes.first?.renderBounds.center)
        #expect(abs(out.x - point.x) < 1.0)
        #expect(abs(out.y - point.y) < 1.0)
    }

    @Test func `displayPage shows only the requested page`() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 120)
        let stroke = PaintTestSupport.dot(at: CGPoint(x: 50, y: 60))
        let captured = PDFAnnotationAnchoring.capturePage(strokes: [stroke], pageIndex: 2, pageFrame: frame)
        #expect(PDFAnnotationAnchoring.displayPage(captured, pageIndex: 5, pageFrame: frame).strokes.isEmpty)
        #expect(!PDFAnnotationAnchoring.displayPage(captured, pageIndex: 2, pageFrame: frame).strokes.isEmpty)
    }
}
