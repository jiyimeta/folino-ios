import CoreGraphics
import Domain
import Foundation
import PencilKit
@testable import Reader
@testable import ReaderAnnotationCore
import Testing
import UIKit

@Suite("AnnotatedPDFComposer")
struct AnnotatedPDFComposerTests {
    /// A two-page PDF with real vector content: a filled rectangle and a line per page.
    private static func baseDocument(pages: Int, size: CGSize = CGSize(width: 400, height: 600)) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var box = CGRect(origin: .zero, size: size)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0 ..< pages {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0.5, alpha: 1)
            context.fill(CGRect(x: 10, y: 10, width: 100, height: 40))
            context.setStrokeColor(gray: 0, alpha: 1)
            context.stroke(CGRect(x: 20, y: 200, width: 300, height: 100))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// One stored drawing whose geometry is a short diagonal in normalized space.
    private static func drawing(kind: DrawingAnchorKind) -> DrawingAnchor {
        let stroke = InkStroke(
            tool: .pen, colorRGBA: 0xFF00_00FF, baseWidthSp: 0.2, opacity: 1,
            x: [0, 0.1, 0.2], y: [0, 0.1, 0.2], width: [0.2, 0.2, 0.2],
            force: [1, 1, 1], azimuth: [], altitude: [], timeMillis: [0, 1, 2],
        )
        return DrawingAnchor(kind: kind, encodedDrawing: InkStrokeCodec.encode(stroke))
    }

    private static func open(_ data: Data) throws -> CGPDFDocument {
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGPDFDocument(provider))
    }

    private static func xObjectCount(of document: CGPDFDocument, page index: Int) throws -> Int {
        let page = try #require(document.page(at: index))
        let dict = try #require(page.dictionary)
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return 0 }
        var bucket: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &bucket), let bucket else { return 0 }
        return CGPDFDictionaryGetCount(bucket)
    }

    @Test
    @MainActor
    func `composing with no placements returns a document with the same pages`() throws {
        let base = try Self.baseDocument(pages: 2)
        let out = try AnnotatedPDFComposer.compose(basePDF: base, drawings: [], placements: [])
        #expect(try Self.open(out).numberOfPages == 2)
    }

    @Test
    @MainActor
    func `the composed page keeps the base page's size`() throws {
        let base = try Self.baseDocument(pages: 1, size: CGSize(width: 400, height: 600))
        let out = try AnnotatedPDFComposer.compose(basePDF: base, drawings: [], placements: [])
        let page = try #require(try Self.open(out).page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        #expect(abs(box.width - 400) < 0.5)
        #expect(abs(box.height - 600) < 0.5)
    }

    @Test
    @MainActor
    func `an annotated page gains an image and an unannotated one does not`() throws {
        let base = try Self.baseDocument(pages: 2)
        let drawings = [Self.drawing(kind: .page(PageAnchor(pageIndex: 0)))]
        let placements = [
            InkPlacement(pageIndex: 0, drawingIndex: 0, transform: StrokeTransform(sp: 400, px: 0, py: 0)),
        ]
        let out = try AnnotatedPDFComposer.compose(
            basePDF: base, drawings: drawings, placements: placements,
        )
        let document = try Self.open(out)
        #expect(try Self.xObjectCount(of: document, page: 1) > 0)
        #expect(try Self.xObjectCount(of: document, page: 2) == 0)
    }

    @Test
    @MainActor
    func `a placement pointing past the base document's pages is skipped`() throws {
        let base = try Self.baseDocument(pages: 1)
        let drawings = [Self.drawing(kind: .page(PageAnchor(pageIndex: 9)))]
        let placements = [
            InkPlacement(pageIndex: 9, drawingIndex: 0, transform: StrokeTransform(sp: 400, px: 0, py: 0)),
        ]
        let out = try AnnotatedPDFComposer.compose(
            basePDF: base, drawings: drawings, placements: placements,
        )
        #expect(try Self.open(out).numberOfPages == 1)
    }

    @Test
    @MainActor
    func `a placement with an out-of-range drawing index is skipped`() throws {
        let base = try Self.baseDocument(pages: 1)
        let placements = [
            InkPlacement(pageIndex: 0, drawingIndex: 3, transform: StrokeTransform(sp: 400, px: 0, py: 0)),
        ]
        let out = try AnnotatedPDFComposer.compose(basePDF: base, drawings: [], placements: placements)
        #expect(try Self.xObjectCount(of: Self.open(out), page: 1) == 0)
    }

    @Test
    @MainActor
    func `unreadable base bytes throw rather than produce an empty PDF`() {
        #expect(throws: DomainError.self) {
            try AnnotatedPDFComposer.compose(basePDF: Data([0x25, 0x21]), drawings: [], placements: [])
        }
    }
}
