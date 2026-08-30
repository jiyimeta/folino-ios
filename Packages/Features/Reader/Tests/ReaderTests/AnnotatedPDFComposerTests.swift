import CoreGraphics
import Domain
import Foundation
import PDFKit
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

    /// Sets `degrees` as the first page's `/Rotate` entry. `CGContext` (used to author the fixtures above) has no
    /// way to write `/Rotate` itself, so this goes through PDFKit instead: open the plain fixture, set
    /// `PDFPage.rotation`, and re-serialize — the simplest way to get a real rotated fixture without hand-writing
    /// PDF syntax.
    private static func rotated(_ data: Data, degrees: Int) throws -> Data {
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        page.rotation = degrees
        return try #require(document.dataRepresentation())
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

    /// Rasterizes `page` at `scale`× into a white-filled RGBA bitmap, drawn straight into the context's native
    /// bottom-left, y-up space — the same space the page's own content stream (and our composer's ink placement)
    /// is expressed in, so a sample point can be given in plain PDF/page points with no extra flip bookkeeping.
    private static func rasterize(_ page: CGPDFPage, size: CGSize, scale: CGFloat) throws -> CGContext {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)
        return context
    }

    /// The red channel at `point` (in the page's own points, bottom-left origin) inside a bitmap `rasterize`
    /// produced at `scale`. The raw buffer's row 0 is the bitmap's TOP scanline while the context's own drawing
    /// space has y = 0 at the BOTTOM (Core Graphics' standard top-down-buffer / bottom-up-space split), hence the
    /// `context.height - 1 - ...` flip when turning a page-space y into a buffer row. Good enough to tell solid
    /// black ink from a blank white page without needing exact color fidelity.
    private static func redChannel(of context: CGContext, at point: CGPoint, scale: CGFloat) throws -> UInt8 {
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let x = Int(point.x * scale)
        let y = context.height - 1 - Int(point.y * scale)
        return pixels[y * context.bytesPerRow + x * 4]
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
    func `ink lands where it was drawn, not mirrored by the coordinate flip`() throws {
        // A short (20pt) horizontal stroke centered 40pt below the UIKit-space (top-left origin, y-down) top edge,
        // 60pt wide, so a sample taken dead-center is robustly inside the ink regardless of PencilKit's own edge
        // softening. `sp: 1, px: 0, py: 0` is the identity transform, so this placement lands at exactly x = 200,
        // y = 40 in page-local UIKit space with no extra arithmetic to track. The two points must be distinct — an
        // earlier version of this test used a single stationary point twice and PencilKit rendered no ink at all
        // for the resulting zero-length path, which would have made the test pass for the wrong reason (nothing to
        // sample) rather than the right one.
        let stroke = InkStroke(
            tool: .pen, colorRGBA: 0x0000_00FF, baseWidthSp: 60, opacity: 1,
            x: [190, 210], y: [40, 40], width: [60, 60],
            force: [1, 1], azimuth: [0, 0], altitude: [.pi / 2, .pi / 2], timeMillis: [0, 1],
        )
        let drawings = [
            DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: InkStrokeCodec.encode(stroke)),
        ]
        let placements = [
            InkPlacement(pageIndex: 0, drawingIndex: 0, transform: StrokeTransform(sp: 1, px: 0, py: 0)),
        ]
        let base = try Self.baseDocument(pages: 1)
        let out = try AnnotatedPDFComposer.compose(basePDF: base, drawings: drawings, placements: placements)
        let page = try #require(try Self.open(out).page(at: 1))

        // A correct flip puts a mark drawn 40pt from the UIKit top edge 40pt from the PDF page's top edge too —
        // i.e. near PDF-space y = 600 - 40 = 560, not mirrored down near y = 40. `mirrored` is `expected` reflected
        // about the page's vertical center (y = 300): an inverted flip, or a scale/translate applied in the wrong
        // order, would move the ink there instead, and the two points are far enough apart (520pt) that both can
        // never read as ink at once.
        let expected = CGPoint(x: 200, y: 560)
        let mirrored = CGPoint(x: 200, y: 40)
        let context = try Self.rasterize(page, size: CGSize(width: 400, height: 600), scale: 2)
        #expect(try Self.redChannel(of: context, at: expected, scale: 2) < 128, "expected ink near the top edge")
        #expect(try Self.redChannel(of: context, at: mirrored, scale: 2) > 200, "expected blank page near the bottom")
    }

    @Test
    @MainActor
    func `a rotated source page exports upright, with ink still where it was drawn`() throws {
        // A 40×40 mark near the unrotated page's top-right corner — well off the page's center — so a 90°
        // rotation moves it to a clearly different spot rather than leaving it roughly in place.
        let markRect = CGRect(x: 300, y: 500, width: 40, height: 40)
        let unrotated = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: unrotated))
        var box = CGRect(origin: .zero, size: CGSize(width: 400, height: 600))
        let markContext = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        markContext.beginPDFPage(nil)
        markContext.setFillColor(gray: 0, alpha: 1)
        markContext.fill(markRect)
        markContext.endPDFPage()
        markContext.closePDF()
        let base = try Self.rotated(unrotated as Data, degrees: 90)

        // Predict where the mark should land using the SAME CoreGraphics API the composer concatenates —
        // `getDrawingTransform` — rather than hand-deriving the rotation/fit math, so this is decisive about
        // whether the composer applies that transform at all, without being fragile to its exact geometry.
        let sourcePage = try #require(try Self.open(base).page(at: 1))
        let destinationBox = CGRect(origin: .zero, size: sourcePage.getBoxRect(.mediaBox).size)
        let transform = sourcePage.getDrawingTransform(
            .mediaBox, rect: destinationBox, rotate: 0, preserveAspectRatio: true,
        )
        let markCenter = CGPoint(x: markRect.midX, y: markRect.midY)
        let rotationCorrected = markCenter.applying(transform)
        let unrotatedPosition = markCenter // where an un-adjusted `drawPDFPage` would leave it

        // A stroke placed the same way as `ink lands where it was drawn...` above — rotation must not perturb
        // the ink math at all, since `pageSize` stays the source's raw (unrotated) box size either way.
        let stroke = InkStroke(
            tool: .pen, colorRGBA: 0x0000_00FF, baseWidthSp: 60, opacity: 1,
            x: [190, 210], y: [40, 40], width: [60, 60],
            force: [1, 1], azimuth: [0, 0], altitude: [.pi / 2, .pi / 2], timeMillis: [0, 1],
        )
        let drawings = [
            DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: InkStrokeCodec.encode(stroke)),
        ]
        let placements = [
            InkPlacement(pageIndex: 0, drawingIndex: 0, transform: StrokeTransform(sp: 1, px: 0, py: 0)),
        ]

        let out = try AnnotatedPDFComposer.compose(basePDF: base, drawings: drawings, placements: placements)
        let page = try #require(try Self.open(out).page(at: 1))

        // Destination media box keeps the source's raw (unrotated) size — no page-size swap.
        let outBox = page.getBoxRect(.mediaBox)
        #expect(abs(outBox.width - 400) < 0.5)
        #expect(abs(outBox.height - 600) < 0.5)

        let context = try Self.rasterize(page, size: destinationBox.size, scale: 2)
        #expect(
            try Self.redChannel(of: context, at: rotationCorrected, scale: 2) < 128,
            "expected the mark at the rotation-corrected position",
        )
        #expect(
            try Self.redChannel(of: context, at: unrotatedPosition, scale: 2) > 200,
            "expected blank page at the un-rotated position — drawPDFPage must honor /Rotate",
        )
        #expect(try Self.redChannel(of: context, at: CGPoint(x: 200, y: 560), scale: 2) < 128, "ink near top edge")
        #expect(try Self.redChannel(of: context, at: CGPoint(x: 200, y: 40), scale: 2) > 200, "no ink near bottom")
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
