import CoreGraphics
import Domain
import Foundation
@testable import ReaderAnnotationCore
import Testing

@Suite("AK ink geometry")
struct AKInkGeometryTests {
    private func stroke(x: [Float], y: [Float], width: [Float]) -> InkStroke {
        InkStroke(
            tool: .pen, colorRGBA: 0xFF00_00FF, baseWidthSp: 2, opacity: 1,
            x: x, y: y, width: width, force: [], azimuth: [], altitude: [], timeMillis: [],
        )
    }

    @Test
    func `the ink box is the point extent grown by half the widest sample plus a point`() throws {
        let box = try #require(AKInkGeometry.inkBox(of: [stroke(x: [10, 30], y: [20, 40], width: [2, 4])]))
        // half of 4 = 2, plus 1 point of slack -> grow by 3 on every side
        #expect(box == CGRect(x: 7, y: 17, width: 26, height: 26))
    }

    @Test
    func `the canvas scale cancels out of the archive rectangle`() {
        // drawingSize is the page scaled by the same factor the box is, so sx and sy are its reciprocal and the
        // archive rectangle is the ink box with y flipped -- nothing else. This invariant is what keeps the three
        // rectangles exactly consistent instead of nearly consistent.
        let page = CGSize(width: 595, height: 842)
        let ink = CGRect(x: 100, y: 200, width: 50, height: 30)
        let size = AKInkGeometry.drawingSize(pageSize: page)
        let sx = page.width / size.width
        let sy = page.height / size.height
        let canvas = AKInkGeometry.canvasBox(ink)

        let rect = AKInkGeometry.archiveRect(ink, pageHeight: page.height)
        #expect(abs(rect.minX - canvas.minX * sx) < 0.000_01)
        #expect(abs(rect.minY - (page.height - (canvas.minY + canvas.height) * sy)) < 0.000_01)
        #expect(abs(rect.minX - ink.minX) < 0.000_01)
        #expect(abs(rect.minY - (page.height - ink.maxY)) < 0.000_01)
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
        let ink = CGRect(x: 100, y: 200, width: 50, height: 30)
        let real = AKInkGeometry.archiveRect(ink, pageHeight: 842)
        let nominal = AKInkGeometry.archiveRect(ink, pageHeight: 841.8898)
        #expect(abs(real.minY - nominal.minY) > 0.1)
    }

    @Test
    func `an empty stroke has no box`() {
        #expect(AKInkGeometry.inkBox(of: [stroke(x: [], y: [], width: [])]) == nil)
    }
}
