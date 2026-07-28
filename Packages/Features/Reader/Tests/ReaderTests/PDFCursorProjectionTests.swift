import CoreGraphics
import Foundation
@testable import ReaderAnnotationCore
import Testing

struct PDFCursorProjectionTests {
    /// A page laid out 1:1 with its own point size only needs the page's origin added.
    @Test func `an unscaled page frame only translates the cursor`() throws {
        let rect = try #require(PDFCursorProjection.displayRect(
            cursorRect: CGRect(x: 10, y: 20, width: 4, height: 60),
            geometryPageWidthPt: 595,
            pageFrame: CGRect(x: 8, y: 1000, width: 595, height: 842),
        ))
        #expect(rect == CGRect(x: 18, y: 1020, width: 4, height: 60))
    }

    /// A page rendered wider than its point size scales both axes by the SAME factor (uniform page scale), so the
    /// cursor bar keeps its aspect ratio.
    @Test func `a rendered page scales the cursor uniformly`() throws {
        let rect = try #require(PDFCursorProjection.displayRect(
            cursorRect: CGRect(x: 100, y: 200, width: 5, height: 50),
            geometryPageWidthPt: 500,
            pageFrame: CGRect(x: 0, y: 0, width: 1000, height: 1400),
        ))
        #expect(rect == CGRect(x: 200, y: 400, width: 10, height: 100))
    }

    /// The page origin is NOT scaled — it is already in the surface's own space.
    @Test func `the page origin is added after scaling`() throws {
        let rect = try #require(PDFCursorProjection.displayRect(
            cursorRect: CGRect(x: 10, y: 10, width: 2, height: 20),
            geometryPageWidthPt: 100,
            pageFrame: CGRect(x: 7, y: 300, width: 200, height: 280),
        ))
        #expect(rect == CGRect(x: 27, y: 320, width: 4, height: 40))
    }

    /// A page whose size the importer never recorded encodes as 0 — there is no scale to apply, so nothing is drawn
    /// rather than something drawn wrong.
    @Test func `an unknown side-car page width refuses to place`() {
        #expect(PDFCursorProjection.displayRect(
            cursorRect: CGRect(x: 10, y: 20, width: 4, height: 60),
            geometryPageWidthPt: 0,
            pageFrame: CGRect(x: 0, y: 0, width: 595, height: 842),
        ) == nil)
    }

    /// A page that isn't laid out this frame (paged mode's zero-width placeholder for every off-screen page).
    @Test func `a page with no current frame refuses to place`() {
        #expect(PDFCursorProjection.displayRect(
            cursorRect: CGRect(x: 10, y: 20, width: 4, height: 60),
            geometryPageWidthPt: 595,
            pageFrame: CGRect(x: 0, y: 0, width: 0, height: 0),
        ) == nil)
    }

    @Test func `page widths within half a point agree`() {
        #expect(PDFCursorProjection.pageWidthsAgree(renderedPageWidthPt: 595, geometryPageWidthPt: 595))
        #expect(PDFCursorProjection.pageWidthsAgree(renderedPageWidthPt: 595.4, geometryPageWidthPt: 595))
        #expect(PDFCursorProjection.pageWidthsAgree(renderedPageWidthPt: 594.6, geometryPageWidthPt: 595))
        #expect(PDFCursorProjection.pageWidthsAgree(renderedPageWidthPt: 595, geometryPageWidthPt: 595.5))
    }

    @Test func `page widths further apart than half a point disagree`() {
        #expect(!PDFCursorProjection.pageWidthsAgree(renderedPageWidthPt: 596, geometryPageWidthPt: 595))
        #expect(!PDFCursorProjection.pageWidthsAgree(renderedPageWidthPt: 595, geometryPageWidthPt: 612))
    }

    /// Nothing to disagree with — the side-car simply didn't record this page.
    @Test func `an unknown side-car page width never reports a mismatch`() {
        #expect(PDFCursorProjection.pageWidthsAgree(renderedPageWidthPt: 595, geometryPageWidthPt: 0))
    }

    // MARK: - Tap direction (the inverse)

    /// The property that matters: `pagePoint` undoes exactly what `displayRect` did, at any page scale/origin.
    @Test func `pagePoint round-trips displayRect`() throws {
        let pageFrame = CGRect(x: 7, y: 300, width: 1190, height: 1684)
        let placed = try #require(PDFCursorProjection.displayRect(
            cursorRect: CGRect(x: 123, y: 456, width: 4, height: 60),
            geometryPageWidthPt: 595,
            pageFrame: pageFrame,
        ))
        let back = try #require(PDFCursorProjection.pagePoint(
            contentPoint: CGPoint(x: placed.minX, y: placed.minY),
            geometryPageWidthPt: 595,
            pageFrame: pageFrame,
        ))
        #expect(back == CGPoint(x: 123, y: 456))
    }

    @Test func `pagePoint subtracts the page origin before dividing`() throws {
        let point = try #require(PDFCursorProjection.pagePoint(
            contentPoint: CGPoint(x: 27, y: 320),
            geometryPageWidthPt: 100,
            pageFrame: CGRect(x: 7, y: 300, width: 200, height: 280),
        ))
        #expect(point == CGPoint(x: 10, y: 10))
    }

    /// The same two declines `displayRect` makes, for the same two reasons.
    @Test func `pagePoint refuses an unknown width or an unlaid-out page`() {
        #expect(PDFCursorProjection.pagePoint(
            contentPoint: CGPoint(x: 10, y: 10),
            geometryPageWidthPt: 0,
            pageFrame: CGRect(x: 0, y: 0, width: 595, height: 842),
        ) == nil)
        #expect(PDFCursorProjection.pagePoint(
            contentPoint: CGPoint(x: 10, y: 10),
            geometryPageWidthPt: 595,
            pageFrame: CGRect(x: 0, y: 0, width: 0, height: 0),
        ) == nil)
    }

    /// A continuous surface: page 1 sits below page 0 plus a gap, and a tap inside it resolves against ITS origin.
    @Test func `pageHit picks the page containing the point`() throws {
        let hit = try #require(PDFCursorProjection.pageHit(
            contentPoint: CGPoint(x: 100, y: 1000),
            geometryPageWidthsPt: [595, 595],
            pageFrames: [
                CGRect(x: 0, y: 0, width: 595, height: 842),
                CGRect(x: 0, y: 862, width: 595, height: 842),
            ],
        ))
        #expect(hit == PDFCursorProjection.PageHit(pageIndex: 1, point: CGPoint(x: 100, y: 138)))
    }

    /// The gutter between two pages is a tap on NOTHING — deliberately unlike `PageAnchoringCore`'s centroid
    /// resolution, which falls back to the nearest page because a stroke has to be filed somewhere.
    @Test func `pageHit declines a point in the inter-page gutter`() {
        #expect(PDFCursorProjection.pageHit(
            contentPoint: CGPoint(x: 100, y: 850),
            geometryPageWidthsPt: [595, 595],
            pageFrames: [
                CGRect(x: 0, y: 0, width: 595, height: 842),
                CGRect(x: 0, y: 862, width: 595, height: 842),
            ],
        ) == nil)
    }

    /// Paged mode: every off-screen page is a zero-width placeholder, so only the one visible page can be hit —
    /// and a tap in the letterbox margin beside it hits nothing.
    @Test func `pageHit ignores zero-width placeholder pages`() throws {
        let frames = [
            CGRect(x: 0, y: 0, width: 0, height: 0),
            CGRect(x: 0, y: 0, width: 400, height: 566),
            CGRect(x: 0, y: 0, width: 0, height: 0),
        ]
        let hit = try #require(PDFCursorProjection.pageHit(
            contentPoint: CGPoint(x: 200, y: 283),
            geometryPageWidthsPt: [595, 595, 595],
            pageFrames: frames,
        ))
        #expect(hit.pageIndex == 1)
        #expect(PDFCursorProjection.pageHit(
            contentPoint: CGPoint(x: 500, y: 283),
            geometryPageWidthsPt: [595, 595, 595],
            pageFrames: frames,
        ) == nil)
    }

    /// A page the side-car never measured can't be scaled into, so a tap on it resolves to nothing rather than to a
    /// wrong point — and the scan keeps going rather than stopping at that page.
    @Test func `pageHit skips a page with no side-car width`() {
        #expect(PDFCursorProjection.pageHit(
            contentPoint: CGPoint(x: 100, y: 100),
            geometryPageWidthsPt: [0],
            pageFrames: [CGRect(x: 0, y: 0, width: 595, height: 842)],
        ) == nil)
    }

    /// A widths array shorter than the layout reads as "unknown" past its end (the side-car omits a trailing run of
    /// pages it never recorded), so those pages are skipped instead of trapping on an out-of-range index.
    @Test func `pageHit treats a short widths array as unknown`() {
        #expect(PDFCursorProjection.pageHit(
            contentPoint: CGPoint(x: 100, y: 1000),
            geometryPageWidthsPt: [595],
            pageFrames: [
                CGRect(x: 0, y: 0, width: 595, height: 842),
                CGRect(x: 0, y: 862, width: 595, height: 842),
            ],
        ) == nil)
    }

    @Test func `pageHit declines an empty layout`() {
        #expect(PDFCursorProjection.pageHit(
            contentPoint: CGPoint(x: 1, y: 1), geometryPageWidthsPt: [], pageFrames: [],
        ) == nil)
    }
}
