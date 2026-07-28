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
}
