import CoreGraphics
import Foundation
@testable import ReaderAnnotationCore
import Testing

@Suite("AK ink geometry")
struct AKInkGeometryTests {
    @Test
    func `the canvas scale cancels out of the archive rectangle`() {
        // drawingSize is the page scaled by the same factor the drawing is, so the archive rectangle is the
        // drawing's bounds divided back into page points with y flipped -- nothing else. This invariant is what
        // keeps the three rectangles exactly consistent instead of nearly consistent.
        let page = CGSize(width: 595, height: 842)
        let boundsInPage = CGRect(x: 100, y: 200, width: 50, height: 30) // top-left origin, y down
        let k = AKInkGeometry.canvasScale
        let canvasBounds = CGRect(
            x: boundsInPage.minX * k, y: boundsInPage.minY * k,
            width: boundsInPage.width * k, height: boundsInPage.height * k,
        )
        let size = AKInkGeometry.drawingSize(pageSize: page)
        #expect(abs(size.width / page.width - k) < 0.000_01)

        let rect = AKInkGeometry.archiveRect(canvasBounds: canvasBounds, pageHeight: page.height)
        #expect(abs(rect.minX - boundsInPage.minX) < 0.000_01)
        #expect(abs(rect.minY - (page.height - boundsInPage.maxY)) < 0.000_01)
        #expect(abs(rect.width - boundsInPage.width) < 0.000_01)
        #expect(abs(rect.height - boundsInPage.height) < 0.000_01)
    }

    @Test
    func `the annotation rectangle is the archive rectangle grown one point on every side`() {
        let archive = CGRect(x: 145.6, y: 497.5, width: 228.1, height: 8.2)
        #expect(AKInkGeometry.annotationRect(archive)
            == CGRect(x: 144.6, y: 496.5, width: 230.1, height: 10.2))
    }

    @Test
    func `the page height must be the real MediaBox, not A4's nominal size`() {
        // A page that is really 595 x 842 against A4's nominal 841.8898 puts the rectangle about 0.11pt out,
        // which is enough for the annotation to be rejected outright. This pins the difference so nobody
        // "tidies" the page size into a constant later.
        let bounds = CGRect(x: 100, y: 200, width: 50, height: 30)
        let real = AKInkGeometry.archiveRect(canvasBounds: bounds, pageHeight: 842)
        let nominal = AKInkGeometry.archiveRect(canvasBounds: bounds, pageHeight: 841.8898)
        #expect(abs(real.minY - nominal.minY) > 0.1)
    }
}
