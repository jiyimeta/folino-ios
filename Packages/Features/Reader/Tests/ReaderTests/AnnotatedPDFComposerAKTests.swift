import CoreGraphics
import Domain
import Foundation
import PDFKit
import PencilKit
@testable import Reader
@testable import ReaderAnnotationCore
import Testing
import UIKit

/// The Apple-ink half of the composer: every stamped annotation carries an `AKAnnotationV2` archive, no two
/// annotations claim the same drawing, and the annotation's `/Rect` is the one `AKInkGeometry` derives from the
/// page's REAL media box.
@MainActor
@Suite("AnnotatedPDFComposer — Apple ink payload")
struct AnnotatedPDFComposerAKTests {
    /// A one-page document whose media box is exactly `size`. Authored with `CGContext` rather than
    /// `UIGraphicsPDFRenderer` because the media box has to survive to four decimals — see `realMediaBoxHeight`.
    private static func onePagePDF(size: CGSize) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var box = CGRect(origin: .zero, size: size)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.stroke(CGRect(x: 10, y: 10, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// One placed-at-the-origin stroke, in page-local points once the placement below is applied.
    private static func drawing() -> DrawingAnchor {
        let stroke = InkStroke(
            tool: .pen, colorRGBA: 0xFF33_22FF, baseWidthSp: 2, opacity: 1,
            x: [10, 30, 50], y: [20, 40, 20], width: [2, 2, 2],
            force: [], azimuth: [], altitude: [], timeMillis: [],
        )
        return DrawingAnchor(
            kind: .page(PageAnchor(pageIndex: 0)),
            encodedDrawing: InkStrokeCodec.encode(stroke),
        )
    }

    private static let placement = InkPlacement(
        pageIndex: 0, drawingIndex: 0, transform: StrokeTransform(sp: 1, px: 100, py: 100),
    )

    /// The `AAPL:AKAnnotationV2` base64 string on `annotation`, or nil.
    ///
    /// Read through `value(forAnnotationKey:)`, NOT `annotationKeyValues`: PDFKit does not enumerate
    /// `/AAPL:AKExtras` among an annotation's keys on the way back in, so the obvious spelling reports nil for a
    /// key that is demonstrably in the file. The inner dictionary's keys do come back in PDFKit's own box type
    /// with a leading slash, hence the substring match on that level.
    static func akPayloadString(of annotation: PDFAnnotation) -> String? {
        let extras = annotation.value(
            forAnnotationKey: PDFAnnotationKey(rawValue: "AAPL:AKExtras"),
        ) as? [AnyHashable: Any]
        return extras?.first { "\($0.key)".contains("AKAnnotationV2") }?.value as? String
    }

    @Test
    func `every ink annotation carries an AKAnnotationV2 payload`() throws {
        let result = try AnnotatedPDFComposer.compose(
            basePDF: Self.onePagePDF(size: CGSize(width: 595, height: 842)),
            drawings: [Self.drawing()],
            placements: [Self.placement],
        )
        #expect(result.akEncodeFailures == 0, "a plain FINK stroke must never fail to encode")
        let page = try #require(PDFDocument(data: result.data)?.page(at: 0))
        let annotation = try #require(page.annotations.first)
        let base64 = try #require(Self.akPayloadString(of: annotation))
        #expect(Data(base64Encoded: base64)?.isEmpty == false)
    }

    /// AnnotationKit names a drawing by the identifiers inside its payload rather than by the annotation holding
    /// it, so two annotations sharing a payload are one drawing — an eraser stroke on one would delete the other,
    /// on whatever page it happens to be.
    @Test
    func `no two annotations in a document share an identifier`() throws {
        let result = try AnnotatedPDFComposer.compose(
            basePDF: Self.onePagePDF(size: CGSize(width: 595, height: 842)),
            drawings: [Self.drawing(), Self.drawing()],
            placements: [
                InkPlacement(pageIndex: 0, drawingIndex: 0, transform: StrokeTransform(sp: 1, px: 100, py: 100)),
                InkPlacement(pageIndex: 0, drawingIndex: 1, transform: StrokeTransform(sp: 1, px: 100, py: 300)),
            ],
        )
        let page = try #require(PDFDocument(data: result.data)?.page(at: 0))
        let payloads = page.annotations.compactMap { Self.akPayloadString(of: $0) }
        #expect(payloads.count == 2)
        #expect(payloads[0] != payloads[1])
    }

    @Test
    func `the annotation rectangle is the archive rectangle grown one point`() throws {
        let result = try AnnotatedPDFComposer.compose(
            basePDF: Self.onePagePDF(size: CGSize(width: 595, height: 842)),
            drawings: [Self.drawing()], placements: [Self.placement],
        )
        let page = try #require(PDFDocument(data: result.data)?.page(at: 0))
        let bounds = try #require(page.annotations.first).bounds

        var stroke = try InkStrokeCodec.decode(Self.drawing().encodedDrawing)
        stroke.x = stroke.x.map { $0 * 1 + 100 }
        stroke.y = stroke.y.map { $0 * 1 + 100 }
        let box = try #require(AKInkGeometry.inkBox(of: [stroke]))
        let expected = AKInkGeometry.annotationRect(
            AKInkGeometry.archiveRect(box, pageHeight: page.bounds(for: .mediaBox).height),
        )
        #expect(abs(bounds.minX - expected.minX) < 0.001)
        #expect(abs(bounds.minY - expected.minY) < 0.001)
        #expect(abs(bounds.width - expected.width) < 0.001)
        #expect(abs(bounds.height - expected.height) < 0.001)
    }

    // MARK: Reading the rectangle back out of a payload

    /// `PropertyListSerialization` hands a `CF$UID` back as an opaque `CFKeyedArchiverUID` that answers no typed
    /// accessor, so the index it wraps is parsed out of its `-description`. Same approach as `AKInkArchiveTests`,
    /// which explains it at length; test-only, production code never inspects a UID this way.
    private static func uidIndex(_ any: Any) throws -> Int {
        let text = String(describing: any)
        let afterMarker = try #require(text.range(of: "value = ")).upperBound
        let closeBrace = try #require(text.range(of: "}", range: afterMarker ..< text.endIndex))
        return try #require(Int(text[afterMarker ..< closeBrace.lowerBound]))
    }

    private static func resolved(_ objects: [Any], _ uid: Any) throws -> Any {
        let index = try uidIndex(uid)
        return try #require(objects.indices.contains(index) ? objects[index] : nil)
    }

    /// The `rectangle` an `AKAnnotationV2` archive carries, as page-space (y-up) geometry. This is the value
    /// Apple's markup compares against the annotation's `/Rect`, so reading it back is the only way a test can
    /// tell "this annotation has a payload" apart from "this annotation has ITS payload".
    static func archiveRectangle(base64: String) throws -> CGRect {
        let data = try #require(Data(base64Encoded: base64))
        let root = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        )
        let objects = try #require(root["$objects"] as? [Any])
        let top = try #require(root["$top"] as? [String: Any])
        let rootUID = try #require(top["root"])
        let rootObject = try #require(try resolved(objects, rootUID) as? [String: Any])
        let rectangleUID = try #require(rootObject["rectangle"])
        let rectangle = try #require(try resolved(objects, rectangleUID) as? [String: Any])
        // An archived NSDictionary stores its contents as two parallel UID arrays, so each key and value has to
        // be resolved through `$objects` in turn.
        let keyUIDs = try #require(rectangle["NS.keys"] as? [Any])
        let valueUIDs = try #require(rectangle["NS.objects"] as? [Any])
        var values: [String: Double] = [:]
        for (keyUID, valueUID) in zip(keyUIDs, valueUIDs) {
            let key = try #require(try resolved(objects, keyUID) as? String)
            values[key] = try #require(try resolved(objects, valueUID) as? Double)
        }
        return try CGRect(
            x: #require(values["X"]), y: #require(values["Y"]),
            width: #require(values["Width"]), height: #require(values["Height"]),
        )
    }

    /// A real folino export's measured page height, deliberately not a standard paper size.
    ///
    /// `rectangleAgrees` above reads the page height from the same place the composer does, so it cannot catch the
    /// bug this format is most exposed to: a caller reaching for a NOMINAL size — A4's 841.8898 — against a page
    /// that is really something else. A tenth of a point of disagreement between the annotation's `/Rect` and the
    /// rectangle inside the payload makes Apple's markup discard the annotation in silence: the ink still renders
    /// from folino's own appearance stream, the eraser does nothing, and nothing is logged. So the expected
    /// rectangle here is pinned to this literal, and a hardcoded A4 constant in the composer fails it by 0.195pt.
    private static let realMediaBoxHeight: CGFloat = 841.6944
    private static let realMediaBoxWidth: CGFloat = 595.4458

    @Test
    func `the annotation rectangle follows the page's real media box, not a nominal paper size`() throws {
        let size = CGSize(width: Self.realMediaBoxWidth, height: Self.realMediaBoxHeight)
        let result = try AnnotatedPDFComposer.compose(
            basePDF: Self.onePagePDF(size: size),
            drawings: [Self.drawing()], placements: [Self.placement],
        )
        let page = try #require(PDFDocument(data: result.data)?.page(at: 0))

        // The fixture has to actually carry the odd height, or the assertion below would pass against A4 too.
        let mediaBox = page.bounds(for: .mediaBox)
        #expect(abs(mediaBox.height - Self.realMediaBoxHeight) < 0.001)
        #expect(abs(mediaBox.width - Self.realMediaBoxWidth) < 0.001)

        var stroke = try InkStrokeCodec.decode(Self.drawing().encodedDrawing)
        stroke.x = stroke.x.map { $0 + 100 }
        stroke.y = stroke.y.map { $0 + 100 }
        let box = try #require(AKInkGeometry.inkBox(of: [stroke]))
        // Pinned to the literal, NOT to `mediaBox.height` — that is the whole point of this test.
        let expected = AKInkGeometry.annotationRect(
            AKInkGeometry.archiveRect(box, pageHeight: Self.realMediaBoxHeight),
        )
        let bounds = try #require(page.annotations.first).bounds
        #expect(abs(bounds.minY - expected.minY) < 0.001)
        #expect(abs(bounds.maxY - expected.maxY) < 0.001)
        #expect(abs(bounds.minX - expected.minX) < 0.001)
    }

    /// A pixel-erased stroke keeps its PencilKit `mask`, which the neutral `InkStroke` cannot express, so it gets
    /// no payload. It must still export as a plain `/Ink` annotation — losing the payload is a capability loss,
    /// never a lost mark — and the loss must be counted so the renderer can log it.
    @Test
    func `a stroke that cannot be encoded still exports, and is counted`() throws {
        let points = [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40), CGPoint(x: 50, y: 20)].map {
            PKStrokePoint(
                location: $0, timeOffset: 0, size: CGSize(width: 2, height: 2),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2,
            )
        }
        let masked = PKStroke(
            ink: PKInk(.pen, color: .red),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)),
            transform: .identity,
            mask: UIBezierPath(rect: CGRect(x: 0, y: 0, width: 40, height: 60)),
        )
        let stored = PKDrawing(strokes: [masked]).dataRepresentation()
        try #require(!InkStrokeCodec.isInkStroke(stored))
        try #require(PKDrawing(data: stored).strokes.first?.mask != nil, "the fixture must round-trip its mask")

        let result = try AnnotatedPDFComposer.compose(
            basePDF: Self.onePagePDF(size: CGSize(width: 595, height: 842)),
            drawings: [DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: stored)],
            placements: [Self.placement],
        )
        let page = try #require(PDFDocument(data: result.data)?.page(at: 0))
        let annotation = try #require(page.annotations.first)
        #expect(annotation.type == "Ink")
        #expect(Self.akPayloadString(of: annotation) == nil)
        #expect(result.akEncodeFailures == 1)
    }

    /// The payload is attached on a second pass, by each annotation's position in its page's `/Annots` order. A
    /// page that already carried annotations of its own is where that mapping can slip: get the offset wrong and
    /// the payload lands on somebody else's annotation, or on nothing.
    @Test
    func `payloads land on the right annotation when the page already had some`() throws {
        let plain = try #require(PDFDocument(data: Self.onePagePDF(size: CGSize(width: 595, height: 842))))
        let plainPage = try #require(plain.page(at: 0))
        let existing = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil,
        )
        plainPage.addAnnotation(existing)
        let base = try #require(plain.dataRepresentation())

        let result = try AnnotatedPDFComposer.compose(
            basePDF: base,
            drawings: [Self.drawing(), Self.drawing()],
            placements: [
                InkPlacement(pageIndex: 0, drawingIndex: 0, transform: StrokeTransform(sp: 1, px: 100, py: 100)),
                InkPlacement(pageIndex: 0, drawingIndex: 1, transform: StrokeTransform(sp: 1, px: 100, py: 300)),
            ],
        )
        #expect(result.akEncodeFailures == 0)
        let page = try #require(PDFDocument(data: result.data)?.page(at: 0))
        #expect(page.annotations.contains { $0.type == "Text" }, "the base document's own annotation must survive")
        let ink = page.annotations.filter { $0.type == "Ink" }
        #expect(ink.count == 2)

        // Distinct, non-nil payloads are not enough: two payloads SWAPPED between the two annotations would
        // satisfy that and still be rejected in silence by Apple's markup, because each annotation's /Rect would
        // then disagree with the rectangle inside the payload it carries. So each archive is decoded and checked
        // against its OWN annotation under the three-box rule — /Rect is the archive rectangle grown one point
        // on every side.
        var seen = Set<String>()
        for annotation in ink {
            let base64 = try #require(Self.akPayloadString(of: annotation))
            #expect(seen.insert(base64).inserted, "two annotations must never share a payload")
            let rectangle = try Self.archiveRectangle(base64: base64)
            let expected = annotation.bounds.insetBy(dx: 1, dy: 1)
            #expect(abs(rectangle.minX - expected.minX) < 0.001)
            #expect(abs(rectangle.minY - expected.minY) < 0.001)
            #expect(abs(rectangle.width - expected.width) < 0.001)
            #expect(abs(rectangle.height - expected.height) < 0.001)
        }
    }
}
