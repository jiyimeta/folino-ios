import CoreGraphics
import Domain
import Foundation
import PDFKit
import PencilKit
@testable import Reader
@testable import ReaderAnnotationCore
import SheetMusicCore
import SheetMusicPDF
import Testing
import UIKit

@Suite("AnnotatedPDFComposer")
struct AnnotatedPDFComposerTests {
    /// A two-page PDF with real vector content: a filled rectangle and a line per page.
    static func baseDocument(pages: Int, size: CGSize = CGSize(width: 400, height: 600)) throws -> Data {
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
    static func drawing(kind: DrawingAnchorKind) -> DrawingAnchor {
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

    /// Two strokes in one page-local UIKit-space (top-left origin, y-down) drawing whose combined bounding box is
    /// tall and vertically *asymmetric*: `strokeMark` is a short, wide capsule near the box's own top; `strokeAnchor`
    /// sits far below it but shifted well off to one side in x, so it extends the box downward without adding any
    /// ink under `sampleX`. That asymmetry is the point — a horizontal capsule centered in its own bounding box (the
    /// fixture this replaced) is vertically symmetric, so mirroring it top-to-bottom *inside that box* changes
    /// nothing either sample point can see, even though the box's own placement on the page is unaffected by the
    /// bug this is meant to catch. With this fixture, the two samples below are dead-center on `strokeMark`'s
    /// (ink) and comfortably below it under `sampleX` (background) — content that must trade places if the ink
    /// image is flipped within its own box, and must not if it isn't.
    private static let sampleX: CGFloat = 200

    private static func asymmetricFixture() -> [DrawingAnchor] {
        let strokeMark = InkStroke(
            tool: .pen, colorRGBA: 0x0000_00FF, baseWidthSp: 60, opacity: 1,
            x: [190, 210], y: [40, 40], width: [60, 60],
            force: [1, 1], azimuth: [0, 0], altitude: [.pi / 2, .pi / 2], timeMillis: [0, 1],
        )
        let strokeAnchor = InkStroke(
            tool: .pen, colorRGBA: 0x0000_00FF, baseWidthSp: 60, opacity: 1,
            x: [350, 370], y: [280, 280], width: [60, 60],
            force: [1, 1], azimuth: [0, 0], altitude: [.pi / 2, .pi / 2], timeMillis: [0, 1],
        )
        return [
            DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: InkStrokeCodec.encode(strokeMark)),
            DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: InkStrokeCodec.encode(strokeAnchor)),
        ]
    }

    private static func asymmetricPlacements() -> [InkPlacement] {
        [
            InkPlacement(pageIndex: 0, drawingIndex: 0, transform: StrokeTransform(sp: 1, px: 0, py: 0)),
            InkPlacement(pageIndex: 0, drawingIndex: 1, transform: StrokeTransform(sp: 1, px: 0, py: 0)),
        ]
    }

    @Test
    @MainActor
    func `ink lands where it was drawn, not mirrored by the coordinate flip`() throws {
        let base = try Self.baseDocument(pages: 1)
        let out = try AnnotatedPDFComposer.compose(
            basePDF: base, drawings: Self.asymmetricFixture(), placements: Self.asymmetricPlacements(),
        )
        let page = try #require(try Self.open(out).page(at: 1))

        // `expected` is dead-center on `strokeMark`, mapped straight across the page/PDF-space flip (600 - 40).
        // `mirrored` sits well below it under the same x, still inside the combined bounding box (it's within
        // `strokeAnchor`'s extended box, but away from `strokeAnchor`'s own ink at x = 350...370) — so it reads as
        // background under a correct flip. A composer that mirrors the ink image *inside its own bounding box*
        // (rather than only flipping the box's position) would swap what shows at these two points instead of just
        // moving the box, which is exactly the bug an earlier, vertically symmetric fixture could not see.
        let expected = CGPoint(x: Self.sampleX, y: 560)
        let mirrored = CGPoint(x: Self.sampleX, y: 320)
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

        // The same asymmetric fixture as `ink lands where it was drawn...` above — rotation must not perturb the
        // ink math at all, since `pageSize` stays the source's raw (unrotated) box size either way.
        let out = try AnnotatedPDFComposer.compose(
            basePDF: base, drawings: Self.asymmetricFixture(), placements: Self.asymmetricPlacements(),
        )
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
        #expect(
            try Self.redChannel(of: context, at: CGPoint(x: Self.sampleX, y: 560), scale: 2) < 128,
            "ink near top edge",
        )
        #expect(
            try Self.redChannel(of: context, at: CGPoint(x: Self.sampleX, y: 320), scale: 2) > 200,
            "no ink at the mirror-vulnerable point inside the box",
        )
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

extension AnnotatedPDFComposerTests {
    static func baseDocumentForGuardTest() throws -> Data {
        try baseDocument(pages: 1)
    }

    static func drawingForGuardTest() -> DrawingAnchor {
        drawing(kind: .musical(MusicalAnchor(
            measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
            dxSp: 0, verticalOffsetSp: 0,
        )))
    }
}

/// The real CoreGraphics engraving path, wrapped so the Reader test target does not need to import Infrastructure.
struct CoreGraphicsPDFRendererStub: Domain.ScorePDFRenderer {
    func renderPDF(score: Score, title: String) async throws -> Data {
        try await MainActor.run {
            try PDFExporter.export(score: score, options: PDFExporter.Options(title: title))
        }
    }
}

@Suite("ReaderAnnotatedPDFRenderer")
struct ReaderAnnotatedPDFRendererTests {
    private let _install: Void = LayoutTestSupport.installed

    /// `ScorePDFRenderer` that returns a fixed document, so the renderer's mismatch guard can be exercised without
    /// engraving anything.
    private struct StubPDFRenderer: Domain.ScorePDFRenderer {
        let data: Data
        func renderPDF(score: Score, title: String) throws -> Data {
            data
        }
    }

    private static func score(measures: Int) -> Score {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let bars = (0 ..< measures).map { _ in Measure(voices: [Voice(elements: [.chord(chord)])]) }
        return Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: bars)])],
        )
    }

    @Test
    func `the engraved export is a readable PDF even with no ink`() async throws {
        let renderer = ReaderAnnotatedPDFRenderer(pdfRenderer: CoreGraphicsPDFRendererStub())
        let data = try await renderer.renderAnnotatedEngravedPDF(
            score: Self.score(measures: 8), title: "T", drawings: [],
        )
        let provider = try #require(CGDataProvider(data: data as CFData))
        #expect(try #require(CGPDFDocument(provider)).numberOfPages >= 1)
    }

    @Test
    func `a base PDF that disagrees with the plan comes back unstamped rather than mis-stamped`() async throws {
        // A one-page stub for a score that paginates to several: the guard must notice and skip the ink.
        let stub = try AnnotatedPDFComposerTests.baseDocumentForGuardTest()
        let renderer = ReaderAnnotatedPDFRenderer(pdfRenderer: StubPDFRenderer(data: stub))
        let drawings = [AnnotatedPDFComposerTests.drawingForGuardTest()]
        let data = try await renderer.renderAnnotatedEngravedPDF(
            score: Self.score(measures: 240), title: "T", drawings: drawings,
        )
        #expect(data == stub)
    }

    @Test
    func `a base PDF that disagrees with the plan logs the drift instead of failing silently`() async throws {
        // A one-page stub for a score that paginates to several — same mismatch as the "comes back unstamped"
        // test above, but this one asserts on the signal that mismatch is supposed to leave behind: without it,
        // "the user drew nothing", "no anchor resolved" and "the guard tripped" are indistinguishable.
        let stub = try AnnotatedPDFComposerTests.baseDocumentForGuardTest()
        let analytics = SpyAnalytics()
        let renderer = ReaderAnnotatedPDFRenderer(pdfRenderer: StubPDFRenderer(data: stub), analytics: analytics)
        let drawings = [AnnotatedPDFComposerTests.drawingForGuardTest()]
        _ = try await renderer.renderAnnotatedEngravedPDF(
            score: Self.score(measures: 240), title: "T", drawings: drawings,
        )
        let event = try #require(analytics.event(named: "annotated_export_drifted"))
        #expect(event.parameters["reason"] == .string("page_count"))
    }

    @Test
    func `an agreeing base PDF logs nothing`() async throws {
        // The real engraving path — its own output always agrees with the layout mirror, so this is the negative
        // case for the drift signal above.
        let analytics = SpyAnalytics()
        let renderer = ReaderAnnotatedPDFRenderer(pdfRenderer: CoreGraphicsPDFRendererStub(), analytics: analytics)
        _ = try await renderer.renderAnnotatedEngravedPDF(
            score: Self.score(measures: 8), title: "T", drawings: [],
        )
        #expect(analytics.event(named: "annotated_export_drifted") == nil)
    }

    @Test
    func `the original-PDF export preserves the base document's pages`() async throws {
        let base = try AnnotatedPDFComposerTests.baseDocumentForGuardTest()
        let renderer = ReaderAnnotatedPDFRenderer(pdfRenderer: StubPDFRenderer(data: base))
        let data = try await renderer.renderAnnotatedOriginalPDF(basePDF: base, drawings: [])
        let provider = try #require(CGDataProvider(data: data as CFData))
        #expect(try #require(CGPDFDocument(provider)).numberOfPages == 1)
    }
}
