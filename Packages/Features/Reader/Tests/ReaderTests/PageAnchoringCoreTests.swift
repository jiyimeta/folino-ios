import CoreGraphics
import Domain
import Foundation
@testable import ReaderAnnotationCore
import Testing

struct PageAnchoringCoreTests {
    private let frames = [
        CGRect(x: 0, y: 0, width: 100, height: 200),
        CGRect(x: 0, y: 220, width: 100, height: 200),
    ]

    /// A single-sample "dot" stroke at `point`, so its bounding-box centroid is exactly `point`.
    private func stroke(_ point: (CGFloat, CGFloat), width: Float = 10) -> InkStroke {
        InkStroke(
            tool: .pen, colorRGBA: 0x0000_00FF, baseWidthSp: width, opacity: 1,
            x: [Float(point.0)], y: [Float(point.1)], width: [width],
            force: [], azimuth: [], altitude: [], timeMillis: [],
        )
    }

    @Test func `centroid inside A page resolves to that page`() {
        #expect(PageAnchoringCore.pageIndex(forCentroid: CGPoint(x: 50, y: 100), pageFrames: frames) == 0)
        #expect(PageAnchoringCore.pageIndex(forCentroid: CGPoint(x: 50, y: 300), pageFrames: frames) == 1)
    }

    /// A stroke landing in the gap belongs to the nearest page; an exact tie resolves upward.
    @Test func `centroid in the gap resolves to the nearer page`() {
        #expect(PageAnchoringCore.pageIndex(forCentroid: CGPoint(x: 50, y: 205), pageFrames: frames) == 0)
        #expect(PageAnchoringCore.pageIndex(forCentroid: CGPoint(x: 50, y: 215), pageFrames: frames) == 1)
        #expect(PageAnchoringCore.pageIndex(forCentroid: CGPoint(x: 50, y: 210), pageFrames: frames) == 0)
    }

    @Test func `no pages means no anchor`() {
        #expect(PageAnchoringCore.pageIndex(forCentroid: .zero, pageFrames: []) == nil)
    }

    /// Normalization is a fraction of PAGE WIDTH in both axes, so zoom cancels out.
    @Test func `normalize and display are inverses`() throws {
        let frame = CGRect(x: 10, y: 220, width: 100, height: 200)
        let normalize = try #require(PageAnchoringCore.normalizeTransform(pageFrame: frame))
        let display = try #require(PageAnchoringCore.displayTransform(pageFrame: frame))
        let point = CGPoint(x: 60, y: 320)
        let round = point.applying(normalize).applying(display)
        #expect(abs(round.x - point.x) < 0.0001)
        #expect(abs(round.y - point.y) < 0.0001)
    }

    @Test func `zero width page has no transform`() {
        #expect(PageAnchoringCore.normalizeTransform(pageFrame: CGRect(x: 0, y: 0, width: 0, height: 10)) == nil)
    }

    /// Content-checked, not just counted: a swapped `(onPage, offPage)` tuple would fail this.
    @Test func `partition keeps off page drawings`() {
        let onPage = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 1)), encodedDrawing: Data([1]))
        let elsewhere = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: Data([2]))
        let split = PageAnchoringCore.partitionByPage([onPage, elsewhere], pageIndex: 1)
        #expect(split.onPage.map(\.encodedDrawing) == [Data([1])])
        #expect(split.offPage.map(\.encodedDrawing) == [Data([2])])
    }

    @Test func `display transforms are nil for other pages`() {
        let drawing = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 5)), encodedDrawing: Data([1]))
        #expect(PageAnchoringCore.displayTransforms([drawing], pageFrames: frames) == [nil])
    }

    /// Regression: a `.musical` anchor fed into the page-display path must resolve to `nil` — never to page 0.
    /// This is the exact bug `PdfAnnotationBridge.nativePdfAnnotationDisplayTransforms` had before it started gating
    /// on `anchorKind` (a musical wire's `pageIndex == -1` placeholder, if passed straight to `PageAnchor.init`,
    /// clamps to `0` and would otherwise resolve to a valid, wrong transform).
    @Test func `display transforms are nil for a musical anchor, never page 0`() {
        let musical = DrawingAnchor(
            kind: .musical(MusicalAnchor(
                measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
            )),
            encodedDrawing: Data([1]),
        )
        #expect(PageAnchoringCore.displayTransforms([musical], pageFrames: frames) == [nil])
        #expect(PageAnchoringCore.displayStrokeTransforms([musical], pageFrames: frames) == [nil])
    }

    /// `displayStrokeTransforms` mirrors `displayTransforms`, projected into the `StrokeTransform` (`sp`/`px`/`py`)
    /// shape the JNI bridge encodes — `sp` is the page's own width, `(px, py)` its origin, matching
    /// `displayTransform(pageFrame:)`'s scale-then-translate composition.
    @Test func `displayStrokeTransforms scales by page width and translates to the origin`() {
        let drawing = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 1)), encodedDrawing: Data([1, 2, 3]))
        let transforms = PageAnchoringCore.displayStrokeTransforms([drawing], pageFrames: frames)
        #expect(transforms.count == 1)
        #expect(transforms[0]?.sp == 100)
        #expect(transforms[0]?.px == 0)
        #expect(transforms[0]?.py == 220)
    }

    /// `capture` must resolve the SAME page a direct `pageIndex(forCentroid:pageFrames:)` call would for a centroid
    /// straddling the inter-page gap — the exact scenario where a wrong representative point would land a stroke on
    /// the wrong page.
    @Test func `capture resolves a gap-adjacent stroke to the correct page`() throws {
        let nearPage0 = try #require(PageAnchoringCore.capture(strokes: [stroke((50, 205))], pageFrames: frames).first)
        let nearPage1 = try #require(PageAnchoringCore.capture(strokes: [stroke((50, 215))], pageFrames: frames).first)
        guard case let .page(a0) = nearPage0.kind, case let .page(a1) = nearPage1.kind else {
            Issue.record("expected .page anchors")
            return
        }
        #expect(a0.pageIndex == 0)
        #expect(a1.pageIndex == 1)
    }

    /// `capturePage` must bake the normalize transform into BOTH position and width (width scales by the same
    /// `1 / pageFrame.width` factor as position, since normalize is a uniform scale).
    @Test func `capturePage bakes the normalize transform into position and width`() throws {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 50)
        let s = stroke((60, 45), width: 10)
        let captured = try #require(PageAnchoringCore.capturePage(strokes: [s], pageIndex: 2, pageFrame: frame).first)
        guard case let .page(anchor) = captured.kind else {
            Issue.record("expected .page anchor")
            return
        }
        #expect(anchor.pageIndex == 2)
        let decoded = try InkStrokeCodec.decode(captured.encodedDrawing)
        // normalize = translate(-10, -20) then scale(1/100, 1/100): (60, 45) -> (50, 25) -> (0.5, 0.25).
        #expect(abs(Double(decoded.x[0]) - 0.5) < 0.0001)
        #expect(abs(Double(decoded.y[0]) - 0.25) < 0.0001)
        // width and baseWidthSp scale by the same 1/100 factor as position.
        #expect(abs(Double(decoded.width[0]) - 0.1) < 0.0001)
        #expect(abs(Double(decoded.baseWidthSp) - 0.1) < 0.0001)
    }
}
