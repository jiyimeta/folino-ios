import CoreGraphics
import Domain
import Foundation
import PDFKit
import PencilKit
@testable import Reader
@testable import ReaderAnnotationCore
import SheetMusicCore
import SheetMusicLayout
import SheetMusicPDF
import Testing

/// End-to-end coverage for `ReaderAnnotatedPDFRenderer.renderAnnotatedEngravedPDF`: a real `Score`, laid out and
/// captured the way the Reader actually does it — a real `LayoutDocument`, a real stroke captured through
/// `AnnotationAnchoring.capture` into a real FINK-encoded `InkStroke`, resolved against the real CoreGraphics
/// engraving path (`PDFExporter.export`). `AnnotatedPDFComposerTests` injects synthetic `InkPlacement`s directly and
/// `ReaderAnnotatedPDFRendererTests` passes `drawings: []`, so neither would catch a break in anchor resolution or
/// page-band placement between the Reader's capture path and the export path — the exact seam device QA hit when a
/// PDF named `(annotated)` came back with no ink in it.
@Suite("ReaderAnnotatedPDFRenderer end-to-end")
struct ReaderAnnotatedPDFEndToEndTests {
    private let _install: Void = LayoutTestSupport.installed

    private static func score(measures: Int) -> Score {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let bars = (0 ..< measures).map { _ in Measure(voices: [Voice(elements: [.chord(chord)])]) }
        return Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: bars)])],
        )
    }

    /// The layout the Reader itself builds for this score (real `LayoutEngine.layout`, default `ScoreViewOptions`) —
    /// not the export mirror — so the captured anchor is exactly what a real annotation session would have produced.
    private static func readerLayout(_ score: Score) -> LayoutDocument {
        LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 800)
    }

    /// Whether any page of `document` carries at least one `.ink` annotation — the shape ink now takes in the
    /// exported PDF (a `PDFAnnotation`, not an image XObject in the content stream).
    private static func gainedInk(_ document: PDFDocument) -> Bool {
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if page.annotations.contains(where: { $0.type == "Ink" }) {
                return true
            }
        }
        return false
    }

    @Test
    @MainActor
    func `a stroke captured over a real staff position survives to the exported PDF as ink`() async throws {
        let score = Self.score(measures: 240)
        let document = Self.readerLayout(score)

        // A mark a little above and to the right of measure 4's reference point — representative of a real
        // annotation (a circle drawn around a note), not the reference point itself.
        let docPoint = try #require(
            document.anchorReferencePoint(
                measureIndex: 4, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
            )?.point,
        )
        let target = CGPoint(x: docPoint.x + 6, y: docPoint.y - 4)
        let captured = AnnotationAnchoring.capture(strokes: [PaintTestSupport.dot(at: target)], in: document)
        let anchor = try #require(captured.first)

        let renderer = ReaderAnnotatedPDFRenderer(pdfRenderer: CoreGraphicsPDFRendererStub())
        let data = try await renderer.renderAnnotatedEngravedPDF(score: score, title: "T", drawings: [anchor])

        let out = try #require(PDFDocument(data: data))
        #expect(out.pageCount > 1, "the fixture should paginate, so this is a representative multi-page export")
        #expect(Self.gainedInk(out), "the exported PDF must gain an ink annotation somewhere — the stroke drawn")
    }

    /// Regression coverage for the device QA report: a mark drawn with real headroom above the first staff of the
    /// first page — a circle around the first note that also encloses the space above it, or an arrow pointing down
    /// at it — resolves (in the export layout's smaller print-scale `sp`) to a document point above Y = 0. Page 1's
    /// band is `[0, usableHeight)`, so nothing above `startY == 0` used to match any page and `planEngraved` silently
    /// produced zero placements: the exported file kept the `(annotated)` name but carried no ink at all.
    @Test
    @MainActor
    func `a mark drawn well above the first staff of page 1 still survives export`() async throws {
        let score = Self.score(measures: 240)
        let document = Self.readerLayout(score)

        let docPoint = try #require(
            document.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0)?.point,
        )
        // 60pt above the reference point in the Reader's on-screen layout (sp = 7) is a modest headroom for a
        // circled note — nothing pathological — but resolves to a NEGATIVE document Y once re-scaled against the
        // export layout's much smaller print `sp` (~5pt): exactly the gap `planEngraved` used to drop.
        let target = CGPoint(x: docPoint.x + 6, y: docPoint.y - 60)
        let captured = AnnotationAnchoring.capture(strokes: [PaintTestSupport.dot(at: target)], in: document)
        let anchor = try #require(captured.first)
        guard case let .musical(musicalAnchor) = anchor.kind else {
            Issue.record("expected a musical anchor")
            return
        }
        #expect(musicalAnchor.verticalOffsetSp < 0, "the fixture must actually land above the reference point")

        let renderer = ReaderAnnotatedPDFRenderer(pdfRenderer: CoreGraphicsPDFRendererStub())
        let data = try await renderer.renderAnnotatedEngravedPDF(score: score, title: "T", drawings: [anchor])

        let out = try #require(PDFDocument(data: data))
        #expect(
            Self.gainedInk(out),
            "a mark drawn above the top staff of page 1 must still land on page 1, not be dropped entirely",
        )
    }
}
