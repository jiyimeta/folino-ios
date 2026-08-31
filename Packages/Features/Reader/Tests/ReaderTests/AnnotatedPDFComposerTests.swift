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

    /// Rasterizes `page` at `scale`× into a white-filled RGBA bitmap, drawn straight into the context's native
    /// bottom-left, y-up space — the page's own content-stream space, with no annotations involved (`drawPDFPage`
    /// replays the content stream alone), so this is the "content-stream-only" half of the annotation-vs-flattened
    /// pair below.
    private static func rasterizeContentOnly(_ page: CGPDFPage, size: CGSize, scale: CGFloat) throws -> CGContext {
        let context = try Self.blankContext(size: size, scale: scale)
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)
        return context
    }

    /// Rasterizes `page` THROUGH PDFKIT — content stream and annotations both — into the same bottom-left, y-up
    /// bitmap convention as `rasterizeContentOnly`, so the two can be sampled at identical points. This is what a
    /// real PDF viewer shows; the ink annotation only appears here, never in the content-stream-only rasterization.
    private static func rasterizeWithAnnotations(_ page: PDFPage, size: CGSize, scale: CGFloat) throws -> CGContext {
        let context = try Self.blankContext(size: size, scale: scale)
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context
    }

    private static func blankContext(size: CGSize, scale: CGFloat) throws -> CGContext {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// The red channel at `point` (in the page's own points, bottom-left origin) inside a bitmap rasterized at
    /// `scale`. The raw buffer's row 0 is the bitmap's TOP scanline while the context's own drawing space has y = 0
    /// at the BOTTOM (Core Graphics' standard top-down-buffer / bottom-up-space split), hence the
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
    func `an annotated page gains exactly one annotation whatever its stroke count; other pages gain none`() throws {
        let base = try Self.baseDocument(pages: 2)
        let drawings = [
            Self.drawing(kind: .page(PageAnchor(pageIndex: 0))),
            Self.drawing(kind: .page(PageAnchor(pageIndex: 0))),
        ]
        let placements = [
            InkPlacement(pageIndex: 0, drawingIndex: 0, transform: StrokeTransform(sp: 400, px: 0, py: 0)),
            InkPlacement(pageIndex: 0, drawingIndex: 1, transform: StrokeTransform(sp: 400, px: 50, py: 50)),
        ]
        let out = try AnnotatedPDFComposer.compose(basePDF: base, drawings: drawings, placements: placements)
        let document = try #require(PDFDocument(data: out))
        let firstPage = try #require(document.page(at: 0))
        let secondPage = try #require(document.page(at: 1))
        // Two placements, one page, ONE annotation: Books writes a single stamp per page, so folino does too.
        #expect(firstPage.annotations.filter { $0.type == "Stamp" }.count == 1)
        #expect(secondPage.annotations.isEmpty)

        // …and the single annotation's payload carries BOTH strokes, which is the point of consolidating.
        let exported = try #require(try Self.exportedAnnotations(out).first)
        let extras = try #require(exported.extras)
        let base64 = try Self.text(#require(extras["PPK"]))
        let drawing = try PKDrawing(data: #require(Data(base64Encoded: base64)))
        #expect(drawing.strokes.count == 2)
    }

    /// Two identical-width strokes in one page-local UIKit-space (top-left origin, y-down) drawing, placed 200 points
    /// apart vertically and well away from every page edge so neither one's bounding box gets clipped. `strokeMark`
    /// sits near the page's top under `sampleX`; `strokeAnchor` sits far below it and shifted off to one side in x,
    /// so it adds no ink under `sampleX` at all.
    ///
    /// Two properties come out of that arrangement, and both are load-bearing below. Because the two strokes are the
    /// same width, `PKDrawing.bounds` inflates each by the same amount, so the *distance between the two boxes'
    /// centers* is exactly their 200-point separation whatever that inflation happens to be — which pins the y-flip's
    /// sign and unit scale without pinning PencilKit's padding. And because the ink under `sampleX` is confined to
    /// `strokeMark`, a sample dead-center on it and a sample between the two boxes tell "the ink rendered where the
    /// placement put it" apart from "the ink rendered somewhere else", which is the class of bug that shipped before.
    private static let sampleX: CGFloat = 200
    /// `strokeMark`'s page-local y, and the page-space y it must render at once flipped.
    private static let markPageLocalY: Float = 80
    private static let markPageSpaceY: CGFloat = 600 - CGFloat(markPageLocalY)
    /// `strokeAnchor`'s page-local y. The 200-point separation is what the bounds test pins.
    private static let anchorPageLocalY: Float = 280

    private static func asymmetricFixture() -> [DrawingAnchor] {
        let strokeMark = InkStroke(
            tool: .pen, colorRGBA: 0x0000_00FF, baseWidthSp: 60, opacity: 1,
            x: [190, 210], y: [markPageLocalY, markPageLocalY], width: [60, 60],
            force: [1, 1], azimuth: [0, 0], altitude: [.pi / 2, .pi / 2], timeMillis: [0, 1],
        )
        let strokeAnchor = InkStroke(
            tool: .pen, colorRGBA: 0x0000_00FF, baseWidthSp: 60, opacity: 1,
            x: [300, 320], y: [anchorPageLocalY, anchorPageLocalY], width: [60, 60],
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

    /// Composes a single placement in isolation and returns its one annotation's bounds (bottom-left origin).
    @MainActor
    private static func soleAnnotationBounds(drawing: DrawingAnchor) throws -> CGRect {
        let base = try Self.baseDocument(pages: 1)
        let out = try AnnotatedPDFComposer.compose(
            basePDF: base, drawings: [drawing],
            placements: [InkPlacement(pageIndex: 0, drawingIndex: 0, transform: StrokeTransform(sp: 1, px: 0, py: 0))],
        )
        let document = try #require(PDFDocument(data: out))
        let page = try #require(document.page(at: 0))
        return try #require(page.annotations.first).bounds
    }

    @Test
    @MainActor
    func `an annotation's bounds land where the placement put them, in page space with y flipped`() throws {
        // `strokeMark` is drawn at page-local (top-left, y-down) y = 80; `strokeAnchor` at page-local y = 280, 200
        // points below it. Annotation space is the page's own space with a BOTTOM-LEFT origin, so a correct
        // conversion must reverse that order AND preserve the separation exactly: the mark's box must sit 200 points
        // ABOVE the anchor's. Both strokes are the same width, so `PKDrawing.bounds` inflates each by the same
        // amount and the centers' separation is padding-independent — which is what lets this pin the flip's sign
        // and its unit scale numerically rather than settling for an ordering check.
        let topBounds = try Self.soleAnnotationBounds(drawing: Self.asymmetricFixture()[0])
        let bottomBounds = try Self.soleAnnotationBounds(drawing: Self.asymmetricFixture()[1])

        let separation = CGFloat(Self.anchorPageLocalY - Self.markPageLocalY)
        #expect(
            abs((topBounds.midY - bottomBounds.midY) - separation) < 0.01,
            "expected the flip to put the mark exactly 200 points above the anchor in bottom-left page space",
        )
        #expect(
            topBounds.minY > bottomBounds.maxY,
            "expected the near-the-top mark's bounds entirely above the near-the-bottom mark's, in bottom-left space",
        )
        // Neither box is clipped by the page, so the flip above is measured on unclipped geometry.
        let pageBounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        #expect(pageBounds.contains(topBounds), "expected the top mark's bounds to stay on the page")
        #expect(pageBounds.contains(bottomBounds), "expected the bottom mark's bounds to stay on the page")
    }

    @Test
    @MainActor
    func `rendering through PDFKit shows the ink; rendering only the content stream does not`() throws {
        let base = try Self.baseDocument(pages: 1)
        let out = try AnnotatedPDFComposer.compose(
            basePDF: base, drawings: Self.asymmetricFixture(), placements: Self.asymmetricPlacements(),
        )

        // Dead-center on strokeMark, mapped straight across the page/PDF-space flip.
        let onTheInk = CGPoint(x: Self.sampleX, y: Self.markPageSpaceY)
        // Between the two strokes' boxes, under `sampleX` where only strokeMark ever puts ink: background unless the
        // ink drifted off its placement. The base fixture's own vector content is nowhere near this point.
        let offTheInk = CGPoint(x: Self.sampleX, y: 420)
        let size = CGSize(width: 400, height: 600)

        let cgPage = try #require(try Self.open(out).page(at: 1))
        let contentOnly = try Self.rasterizeContentOnly(cgPage, size: size, scale: 2)
        #expect(
            try Self.redChannel(of: contentOnly, at: onTheInk, scale: 2) > 200,
            "the content stream alone must not carry the ink — it was never rewritten",
        )

        let kitDocument = try #require(PDFDocument(data: out))
        let kitPage = try #require(kitDocument.page(at: 0))
        let withAnnotations = try Self.rasterizeWithAnnotations(kitPage, size: size, scale: 2)
        #expect(
            try Self.redChannel(of: withAnnotations, at: onTheInk, scale: 2) < 128,
            "PDFKit (which draws annotations) must show the ink, at the point the placement put it",
        )
        #expect(
            try Self.redChannel(of: withAnnotations, at: offTheInk, scale: 2) > 200,
            "the ink must be confined to where it was placed, not smeared or shifted across the page",
        )
    }

    @Test
    @MainActor
    func `removing the annotations and re-saving removes the ink`() throws {
        let base = try Self.baseDocument(pages: 1)
        let out = try AnnotatedPDFComposer.compose(
            basePDF: base, drawings: Self.asymmetricFixture(), placements: Self.asymmetricPlacements(),
        )
        let sample = CGPoint(x: Self.sampleX, y: Self.markPageSpaceY)
        let size = CGSize(width: 400, height: 600)
        let document = try #require(PDFDocument(data: out))
        let page = try #require(document.page(at: 0))
        // Assert the ink is there first: without this the erasure below would also "pass" on a document that never
        // carried any ink at all.
        let before = try Self.rasterizeWithAnnotations(page, size: size, scale: 2)
        #expect(try Self.redChannel(of: before, at: sample, scale: 2) < 128)

        for annotation in page.annotations {
            page.removeAnnotation(annotation)
        }
        let stripped = try #require(document.dataRepresentation())

        let strippedDocument = try #require(PDFDocument(data: stripped))
        let strippedPage = try #require(strippedDocument.page(at: 0))
        let context = try Self.rasterizeWithAnnotations(strippedPage, size: size, scale: 2)
        #expect(
            try Self.redChannel(of: context, at: sample, scale: 2) > 200,
            "removing the annotations must remove the ink from what PDFKit renders",
        )
    }

    // MARK: - The Apple Books annotation shape

    /// One exported annotation, read back through CoreGraphics rather than PDFKit. Going through `CGPDFDictionary`
    /// is the point: it reports what actually landed in the FILE, including whether `/AAPL:AKExtras` is a real
    /// dictionary object or was flattened into something else on the way out — which PDFKit's own
    /// `value(forAnnotationKey:)` would happily paper over by handing back whatever it still holds in memory.
    struct ExportedAnnotation {
        var subtype: String?
        var flags: Int?
        var author: String?
        /// `nil` when `/AAPL:AKExtras` is absent OR is not a dictionary. Values are the PDF strings' raw bytes.
        var extras: [String: Data]?
        var rect: CGRect?
        /// `/C`, the annotation's single color, as the PDF's own component array.
        var color: [CGFloat]?
        var hasBorder = false
        var hasDefaultAppearance = false
        var hasModificationDate = false
        var hasInkList = false
        var hasStagingKey = false
        /// The `/AP` → `/N` form XObject's decoded content stream, which is what every non-Apple viewer draws.
        var appearanceContent: String?
    }

    /// A PDF string's raw bytes as text. Everything read here (base64, `/T`) is ASCII, so anything that fails to
    /// decode is a real failure rather than something to paper over with replacement characters.
    private static func text(_ data: Data) throws -> String {
        try #require(String(bytes: data, encoding: .utf8))
    }

    private static func pdfName(_ dict: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, key, &value), let value else { return nil }
        return String(cString: value)
    }

    private static func pdfStringBytes(_ dict: CGPDFDictionaryRef, _ key: String) -> Data? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dict, key, &value), let value,
              let bytes = CGPDFStringGetBytePtr(value) else { return nil }
        return Data(bytes: bytes, count: CGPDFStringGetLength(value))
    }

    private static func pdfInteger(_ dict: CGPDFDictionaryRef, _ key: String) -> Int? {
        var value: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dict, key, &value) else { return nil }
        return value
    }

    private static func has(_ dict: CGPDFDictionaryRef, _ key: String) -> Bool {
        var value: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dict, key, &value)
    }

    /// `/Rect`, which the spec writes as `[x0 y0 x1 y1]` — two corners, not an origin and a size.
    private static func pdfRect(_ dict: CGPDFDictionaryRef, _ key: String) -> CGRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, key, &array), let array, CGPDFArrayGetCount(array) == 4 else { return nil }
        var values: [CGFloat] = []
        for index in 0 ..< 4 {
            var real: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &real) else { return nil }
            values.append(real)
        }
        return CGRect(
            x: min(values[0], values[2]), y: min(values[1], values[3]),
            width: abs(values[2] - values[0]), height: abs(values[3] - values[1]),
        )
    }

    /// Every annotation on `page` of the composed `data`, read straight out of the file.
    static func exportedAnnotations(_ data: Data, page pageNumber: Int = 1) throws -> [ExportedAnnotation] {
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        let page = try #require(document.page(at: pageNumber))
        let pageDictionary = try #require(page.dictionary)
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(pageDictionary, "Annots", &annotations), let annotations else { return [] }

        var result: [ExportedAnnotation] = []
        for index in 0 ..< CGPDFArrayGetCount(annotations) {
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annotations, index, &dictionary), let dictionary else { continue }
            var exported = ExportedAnnotation()
            exported.subtype = pdfName(dictionary, "Subtype")
            exported.flags = pdfInteger(dictionary, "F")
            exported.author = pdfStringBytes(dictionary, "T").flatMap { String(bytes: $0, encoding: .utf8) }
            exported.rect = pdfRect(dictionary, "Rect")
            var colorArray: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "C", &colorArray), let colorArray {
                var components: [CGFloat] = []
                for index in 0 ..< CGPDFArrayGetCount(colorArray) {
                    var real: CGPDFReal = 0
                    if CGPDFArrayGetNumber(colorArray, index, &real) {
                        components.append(real)
                    }
                }
                exported.color = components
            }
            exported.hasBorder = has(dictionary, "Border")
            exported.hasDefaultAppearance = has(dictionary, "DA")
            exported.hasModificationDate = has(dictionary, "M")
            exported.hasInkList = has(dictionary, "InkList")
            exported.hasStagingKey = has(dictionary, "FolinoExportPPK")

            var extras: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "AAPL:AKExtras", &extras), let extras {
                var entries: [String: Data] = [:]
                for key in ["PPK", "PPKType"] {
                    if let bytes = pdfStringBytes(extras, key) {
                        entries[key] = bytes
                    }
                }
                exported.extras = entries
            }

            var appearance: CGPDFDictionaryRef?
            var normal: CGPDFStreamRef?
            if CGPDFDictionaryGetDictionary(dictionary, "AP", &appearance), let appearance,
               CGPDFDictionaryGetStream(appearance, "N", &normal), let normal
            {
                var format: CGPDFDataFormat = .raw
                if let stream = CGPDFStreamCopyData(normal, &format) as Data? {
                    exported.appearanceContent = String(bytes: stream, encoding: .utf8)
                }
            }
            result.append(exported)
        }
        // Every `CGPDFDictionaryRef` above is owned by `document` (through `page`), and ARC is free to release a
        // local after its last mention — which here is well before the loop ends. Pin both until the reads are done.
        withExtendedLifetime(page) {}
        withExtendedLifetime(document) {}
        return result
    }

    /// A one-page export carrying exactly one placed stroke, used by every Books-shape test below.
    @MainActor
    private static func composedWithOneStroke() throws -> Data {
        let base = try Self.baseDocument(pages: 1)
        let drawings = [Self.drawing(kind: .page(PageAnchor(pageIndex: 0)))]
        let placements = [
            InkPlacement(pageIndex: 0, drawingIndex: 0, transform: StrokeTransform(sp: 400, px: 20, py: 30)),
        ]
        return try AnnotatedPDFComposer.compose(basePDF: base, drawings: drawings, placements: placements)
    }

    @Test
    @MainActor
    func `the exported annotation carries the subtype, flags and author Apple Books writes`() throws {
        let exported = try #require(try Self.exportedAnnotations(Self.composedWithOneStroke()).first)
        // `/Stamp`, not `/Ink`: Books uses Stamp for Pencil ink and reserves `/Square` for shape markup.
        #expect(exported.subtype == "Stamp")
        // Print (4) + Locked (128) + LockedContents (512).
        #expect(exported.flags == 644)
        #expect(exported.author == "Mobile User")
        // The common entries Books' own annotations carry, and which PDFKit fills in for us.
        #expect(exported.rect != nil)
        #expect(exported.hasBorder)
        #expect(exported.hasDefaultAppearance)
        #expect(exported.hasModificationDate)
        // Books' stamps have no `/InkList`, and the private staging key must never reach a written file.
        #expect(!exported.hasInkList)
        #expect(!exported.hasStagingKey)
    }

    @Test
    @MainActor
    func `AAPL AKExtras lands in the file as a dictionary holding both PPK and PPKType`() throws {
        let exported = try #require(try Self.exportedAnnotations(Self.composedWithOneStroke()).first)
        // `extras` is non-nil only when `CGPDFDictionaryGetDictionary` succeeded, so this is the assertion that
        // PDFKit really serialized a NESTED DICTIONARY under a custom annotation key rather than flattening it.
        let extras = try #require(exported.extras, "expected /AAPL:AKExtras to be a dictionary object in the file")
        #expect(extras["PPK"] != nil)
        #expect(extras["PPKType"] != nil)
    }

    @Test
    @MainActor
    func `PPKType decodes to the three constant bytes Books stores`() throws {
        let exported = try #require(try Self.exportedAnnotations(Self.composedWithOneStroke()).first)
        let extras = try #require(exported.extras)
        let base64 = try Self.text(#require(extras["PPKType"]))
        #expect(try #require(Data(base64Encoded: base64)) == Data([0x76, 0xB6, 0xB0]))
    }

    /// The `/PPK` blob's whole point is that a PencilKit-aware reader can hand it back to PencilKit, so what has to
    /// survive the PDF round-trip is a decodable `PKDrawing` carrying the PLACED geometry — the stroke as it sits on
    /// the exported page, not the normalized geometry that was stored.
    @Test
    @MainActor
    func `PPK decodes back to the placed PencilKit drawing`() throws {
        let exported = try #require(try Self.exportedAnnotations(Self.composedWithOneStroke()).first)
        let extras = try #require(exported.extras)
        let base64 = try Self.text(#require(extras["PPK"]))
        let decoded = try #require(Data(base64Encoded: base64))
        let drawing = try PKDrawing(data: decoded)
        let points = try Array(#require(drawing.strokes.first).path)
        #expect(drawing.strokes.count == 1)
        #expect(points.count == 3)
        // The fixture's normalized xy are (0, 0), (0.1, 0.1), (0.2, 0.2); the placement scales by 400 and translates
        // by (20, 30), so the middle control point must have landed at (60, 70) — i.e. the transform was baked into
        // the stored blob rather than the stored geometry being copied through untouched.
        #expect(abs(points[1].location.x - 60) < 0.5)
        #expect(abs(points[1].location.y - 70) < 0.5)
    }

    /// The one Books field folino cannot reproduce, pinned so the gap is a measured fact rather than a claim.
    /// Books' `/PPK` decodes to a container beginning `crdt`; `PKDrawing.dataRepresentation()` — through every
    /// construction route there is — emits `wrd` instead. If a future SDK starts emitting `crdt`, this test fails,
    /// and that failure is the good news: the payload would then be byte-shaped like Apple's own.
    @Test
    @MainActor
    func `the PPK container is the one PencilKit's public API emits, which is not Books' crdt`() throws {
        let exported = try #require(try Self.exportedAnnotations(Self.composedWithOneStroke()).first)
        let extras = try #require(exported.extras)
        let base64 = try Self.text(#require(extras["PPK"]))
        let decoded = try #require(Data(base64Encoded: base64))
        let magic = String(bytes: decoded.prefix(3), encoding: .utf8) ?? "?"
        #expect(magic == "wrd", "PencilKit now emits \"\(magic)\" — check whether it reaches Books' \"crdt\"")
    }

    /// Books' own appearance is a raster image XObject (`Do`, no path operators). folino's is deliberately vector,
    /// because the appearance is what every non-Apple viewer draws and vector is the better picture — so this pins
    /// that the two-pass subtype rewrite did NOT cost us the vector appearance PDFKit built in pass one.
    @Test
    @MainActor
    func `the exported annotation's appearance stream is still vector, not a raster image`() throws {
        let exported = try #require(try Self.exportedAnnotations(Self.composedWithOneStroke()).first)
        let content = try #require(exported.appearanceContent, "expected an /AP /N appearance stream")
        #expect(content.contains(" m\n") || content.contains(" m "), "expected a moveto operator")
        #expect(content.contains(" l\n") || content.contains(" l "), "expected lineto operators")
        #expect(content.contains("S"), "expected the path to be stroked")
        #expect(!content.contains(" Do"), "expected no image XObject — the appearance must stay vector")
    }

    /// `asymmetricFixture` puts one stroke near the top of the page and one far below it and off to the side, so a
    /// `/Rect` that only covered one of them — or that covered the wrong one — is impossible to miss.
    @Test
    @MainActor
    func `the page's single annotation covers the union of every stroke placed on it`() throws {
        let base = try Self.baseDocument(pages: 1)
        let out = try AnnotatedPDFComposer.compose(
            basePDF: base, drawings: Self.asymmetricFixture(), placements: Self.asymmetricPlacements(),
        )
        let exported = try Self.exportedAnnotations(out)
        #expect(exported.count == 1)
        let rect = try #require(exported.first?.rect)

        // Each stroke composed on its own gives the box that stroke alone would have claimed; the one-annotation
        // page must cover both of them, and no more than their union plus PencilKit's own bounds padding.
        let topAlone = try Self.soleAnnotationBounds(drawing: Self.asymmetricFixture()[0])
        let bottomAlone = try Self.soleAnnotationBounds(drawing: Self.asymmetricFixture()[1])
        let union = topAlone.union(bottomAlone)
        #expect(rect.contains(union.insetBy(dx: 0.5, dy: 0.5)), "expected /Rect to cover both strokes")
        // …and no more than their union: a /Rect that had quietly grown to the whole page would still "cover" them.
        #expect(abs(rect.minX - union.minX) < 1.5, "expected /Rect to be the union, not the whole page")
        #expect(abs(rect.maxX - union.maxX) < 1.5)
        #expect(abs(rect.minY - union.minY) < 1.5)
        #expect(abs(rect.maxY - union.maxY) < 1.5)
    }

    /// The price of one annotation per page: `PDFAnnotation` carries a single `/C`, so a page whose strokes are
    /// different colors has to settle on one for the appearance stream. The dominant color — most sampled points —
    /// wins. The per-stroke colors are untouched inside `/PPK`, which is where a PencilKit-aware reader looks.
    @Test
    @MainActor
    func `a page mixing colors draws its appearance in the color covering the most points`() throws {
        func stroke(color: UInt32, points: Int, y: Float) -> DrawingAnchor {
            let xs = (0 ..< points).map { Float($0) * 2 + 20 }
            let ink = InkStroke(
                tool: .pen, colorRGBA: color, baseWidthSp: 4, opacity: 1,
                x: xs, y: xs.map { _ in y }, width: xs.map { _ in 4 },
                force: [], azimuth: [], altitude: [], timeMillis: [],
            )
            return DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: InkStrokeCodec.encode(ink))
        }
        // Blue over three points, red over twenty: red covers more of the page's ink, so red must win.
        let drawings = [stroke(color: 0x0000_FFFF, points: 3, y: 100), stroke(color: 0xFF00_00FF, points: 20, y: 200)]
        let placements = (0 ..< 2).map {
            InkPlacement(pageIndex: 0, drawingIndex: $0, transform: StrokeTransform(sp: 1, px: 0, py: 0))
        }
        let out = try AnnotatedPDFComposer.compose(
            basePDF: Self.baseDocument(pages: 1), drawings: drawings, placements: placements,
        )
        let exported = try #require(try Self.exportedAnnotations(out).first)
        let color = try #require(exported.color)
        #expect(color.count == 3)
        #expect(color[0] > 0.9, "expected the dominant red, not the three-point blue")
        #expect(color[2] < 0.1)
    }

    @Test
    @MainActor
    func `each annotated page gets its own annotation and its own strokes`() throws {
        let base = try Self.baseDocument(pages: 3)
        // Two strokes on page 0, one on page 2, nothing on page 1.
        let drawings = (0 ..< 3).map { _ in Self.drawing(kind: .page(PageAnchor(pageIndex: 0))) }
        let placements = [
            InkPlacement(pageIndex: 0, drawingIndex: 0, transform: StrokeTransform(sp: 400, px: 0, py: 0)),
            InkPlacement(pageIndex: 2, drawingIndex: 1, transform: StrokeTransform(sp: 400, px: 0, py: 0)),
            InkPlacement(pageIndex: 0, drawingIndex: 2, transform: StrokeTransform(sp: 400, px: 60, py: 60)),
        ]
        let out = try AnnotatedPDFComposer.compose(basePDF: base, drawings: drawings, placements: placements)

        let strokeCount = { (pageNumber: Int) throws -> Int in
            let annotations = try Self.exportedAnnotations(out, page: pageNumber)
            #expect(annotations.count == 1)
            let extras = try #require(annotations.first?.extras)
            let base64 = try Self.text(#require(extras["PPK"]))
            return try PKDrawing(data: #require(Data(base64Encoded: base64))).strokes.count
        }
        #expect(try strokeCount(1) == 2, "page 1 carries two placements, so its one annotation holds two strokes")
        #expect(try Self.exportedAnnotations(out, page: 2).isEmpty, "page 2 has no ink and must gain no annotation")
        #expect(try strokeCount(3) == 1)
    }

    @Test
    @MainActor
    func `an annotation the base document already carried is left in its own shape`() throws {
        // A pre-existing annotation must not be swept into the Books rewrite: only the ones this composer added
        // carry the staging key, and only those are reshaped.
        let plain = try Self.baseDocument(pages: 1)
        let document = try #require(PDFDocument(data: plain))
        let page = try #require(document.page(at: 0))
        page.addAnnotation(PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil,
        ))
        let base = try #require(document.dataRepresentation())

        let placement = InkPlacement(
            pageIndex: 0, drawingIndex: 0, transform: StrokeTransform(sp: 400, px: 0, py: 0),
        )
        let out = try AnnotatedPDFComposer.compose(
            basePDF: base, drawings: [Self.drawing(kind: .page(PageAnchor(pageIndex: 0)))],
            placements: [placement],
        )
        let exported = try Self.exportedAnnotations(out)
        #expect(exported.contains { $0.subtype == "Text" && $0.extras == nil && $0.flags != 644 })
        #expect(exported.contains { $0.subtype == "Stamp" && $0.extras != nil })
    }

    @Test
    @MainActor
    func `the annotation's line width is the median of the stroke's per-point widths, not the mean`() throws {
        let stroke = InkStroke(
            tool: .pen, colorRGBA: 0x0000_00FF, baseWidthSp: 1, opacity: 1,
            x: [0, 10, 20], y: [0, 0, 0], width: [1, 2, 100],
            force: [], azimuth: [], altitude: [], timeMillis: [],
        )
        let drawing = DrawingAnchor(
            kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: InkStrokeCodec.encode(stroke),
        )
        let base = try Self.baseDocument(pages: 1)
        let out = try AnnotatedPDFComposer.compose(
            basePDF: base, drawings: [drawing],
            placements: [InkPlacement(pageIndex: 0, drawingIndex: 0, transform: StrokeTransform(sp: 1, px: 0, py: 0))],
        )
        let document = try #require(PDFDocument(data: out))
        let annotation = try #require(document.page(at: 0)?.annotations.first)
        let lineWidth = try #require(annotation.border?.lineWidth)
        #expect(abs(lineWidth - 2) < 0.01, "expected the median (2), not the mean (~34.3) or the first sample (1)")
    }

    @Test
    @MainActor
    func `the base document's page count, page sizes and existing annotations survive`() throws {
        let plain = try Self.baseDocument(pages: 2)
        let document = try #require(PDFDocument(data: plain))
        let existingPage = try #require(document.page(at: 0))
        let existing = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil,
        )
        existingPage.addAnnotation(existing)
        let base = try #require(document.dataRepresentation())

        let drawings = [Self.drawing(kind: .page(PageAnchor(pageIndex: 1)))]
        let placements = [
            InkPlacement(pageIndex: 1, drawingIndex: 0, transform: StrokeTransform(sp: 400, px: 0, py: 0)),
        ]
        let out = try AnnotatedPDFComposer.compose(basePDF: base, drawings: drawings, placements: placements)
        let composed = try #require(PDFDocument(data: out))

        #expect(composed.pageCount == 2)
        for index in 0 ..< 2 {
            let page = try #require(composed.page(at: index))
            let box = try #require(document.page(at: index)).bounds(for: .mediaBox)
            #expect(page.bounds(for: .mediaBox) == box)
        }
        let firstPage = try #require(composed.page(at: 0))
        #expect(firstPage.annotations.contains { $0.type == "Text" })
        let secondPage = try #require(composed.page(at: 1))
        #expect(secondPage.annotations.contains { $0.type == "Stamp" })
    }

    @Test
    @MainActor
    func `a rotated source page's rotation and ink annotation both survive composition`() throws {
        let plain = try Self.baseDocument(pages: 1)
        let base = try Self.rotated(plain, degrees: 90)
        let drawings = [Self.drawing(kind: .page(PageAnchor(pageIndex: 0)))]
        let placements = [
            InkPlacement(pageIndex: 0, drawingIndex: 0, transform: StrokeTransform(sp: 400, px: 0, py: 0)),
        ]
        let out = try AnnotatedPDFComposer.compose(basePDF: base, drawings: drawings, placements: placements)
        let document = try #require(PDFDocument(data: out))
        let page = try #require(document.page(at: 0))
        #expect(page.rotation == 90, "the composer never touches the page, so /Rotate must pass through untouched")
        #expect(page.annotations.contains { $0.type == "Stamp" })
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
        let document = try #require(PDFDocument(data: out))
        let page = try #require(document.page(at: 0))
        #expect(page.annotations.isEmpty)
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
