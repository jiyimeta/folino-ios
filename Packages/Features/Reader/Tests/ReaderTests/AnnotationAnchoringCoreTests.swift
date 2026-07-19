import CoreGraphics
import Domain
import Foundation
@testable import Reader
import ReaderAnnotationCore
import SheetMusicCore
import SheetMusicLayout
import Testing

@Suite("AnnotationAnchoringCore")
struct AnnotationAnchoringCoreTests {
    /// Install the CoreText FontMetrics provider so LayoutEngine's precondition passes.
    private let _install: Void = LayoutTestSupport.installed

    private func doc(staffSize: CGFloat = 28) -> LayoutDocument {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure, measure])
        let score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
        )
        var options = ScoreViewOptions()
        options.staffSize = staffSize
        return LayoutEngine.layout(score: score, options: options, availableWidth: 800)
    }

    /// A short document-space stroke as two on-curve samples.
    private func stroke(_ a: CGPoint, _ b: CGPoint, width: Float = 2) -> InkStroke {
        InkStroke(
            tool: .pen, colorRGBA: 0x0000_00FF, baseWidthSp: width, opacity: 1,
            x: [Float(a.x), Float(b.x)], y: [Float(a.y), Float(b.y)], width: [width, width],
            force: [], azimuth: [], altitude: [], timeMillis: [],
        )
    }

    @Test
    func `representativePoint is the geometry bounding-box center`() {
        let s = stroke(CGPoint(x: 10, y: 40), CGPoint(x: 30, y: 20))
        let c = AnnotationAnchoringCore.representativePoint(of: s)
        #expect(c.x == 20)
        #expect(c.y == 30)
    }

    @Test
    func `anchorPoint composes the base reference with the anchor's sp offsets`() throws {
        let d = doc()
        let resolver = LayoutDocumentAnchorResolver(document: d)
        let anchor = MusicalAnchor(
            measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
            dxSp: 1.5, verticalOffsetSp: -2.0,
        )
        let ref = try #require(
            d.anchorReferencePoint(measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0),
        )
        let p = try #require(AnnotationAnchoringCore.anchorPoint(for: anchor, using: resolver))
        #expect(abs(p.point.x - (ref.point.x + 1.5 * ref.sp)) < 0.001)
        #expect(abs(p.point.y - (ref.point.y - 2.0 * ref.sp)) < 0.001)
        #expect(p.sp == ref.sp)
    }

    @Test
    func `capture then display then place recovers document geometry (round-trip)`() throws {
        let d = doc()
        let resolver = LayoutDocumentAnchorResolver(document: d)
        let ref = try #require(
            d.anchorReferencePoint(measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0),
        )
        let a = CGPoint(x: ref.point.x + 30, y: ref.point.y - 12)
        let b = CGPoint(x: ref.point.x + 34, y: ref.point.y - 8)
        let input = stroke(a, b)

        let captured = AnnotationAnchoringCore.capture(strokes: [input], using: resolver)
        #expect(captured.count == 1)

        let transforms = AnnotationAnchoringCore.display(captured, using: resolver)
        #expect(transforms.count == 1)
        let t = try #require(transforms[0])

        let stored = try InkStrokeCodec.decode(captured[0].encodedDrawing)
        let placed = AnnotationAnchoringCore.place(stored, with: t)

        #expect(placed.x.count == 2)
        #expect(abs(placed.x[0] - Float(a.x)) < 0.1)
        #expect(abs(placed.y[0] - Float(a.y)) < 0.1)
        #expect(abs(placed.x[1] - Float(b.x)) < 0.1)
        #expect(abs(placed.y[1] - Float(b.y)) < 0.1)
    }

    @Test
    func `an anchor captured in a wrap layout still displays in a natural-width layout`() throws {
        let wrap = doc()
        var options = ScoreViewOptions()
        options.wrapToViewWidth = false
        options.includeTitleFrame = false
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure, measure])
        let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])
        let natural = LayoutEngine.layout(
            score: score, options: options,
            availableWidth: LayoutEngine.naturalContentWidth(score: score, options: options),
        )

        let ref = try #require(
            wrap.anchorReferencePoint(measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0),
        )
        let s = stroke(
            CGPoint(x: ref.point.x + 20, y: ref.point.y),
            CGPoint(x: ref.point.x + 24, y: ref.point.y),
        )
        let captured = AnnotationAnchoringCore.capture(
            strokes: [s], using: LayoutDocumentAnchorResolver(document: wrap),
        )
        #expect(captured.count == 1)
        // The same musical anchor resolves in the natural-width layout (non-nil transform) — cross-mode sharing.
        let naturalResolver = LayoutDocumentAnchorResolver(document: natural)
        let transforms = AnnotationAnchoringCore.display(captured, using: naturalResolver)
        #expect(transforms[0] != nil)
    }

    @Test
    func `capture drops strokes whose representative point can't resolve`() {
        let empty = LayoutEngine.layout(score: Score(division: 480), options: ScoreViewOptions(), availableWidth: 800)
        let captured = AnnotationAnchoringCore.capture(
            strokes: [stroke(CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20))],
            using: LayoutDocumentAnchorResolver(document: empty),
        )
        #expect(captured.isEmpty)
    }

    @Test
    func `display yields nil for an anchor absent from the layout`() {
        let d = doc()
        let m = MusicalAnchor(
            measureIndex: 99, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
        let transforms = AnnotationAnchoringCore.display(
            [DrawingAnchor(kind: .musical(m), encodedDrawing: Data())],
            using: LayoutDocumentAnchorResolver(document: d),
        )
        #expect(transforms.count == 1)
        #expect(transforms[0] == nil)
    }

    @Test
    func `partitionByPage keeps unresolved anchors off-page, never dropped`() throws {
        let d = doc()
        let resolver = LayoutDocumentAnchorResolver(document: d)
        let p0 = try #require(
            d.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0)?.point,
        )
        let m0 = MusicalAnchor(
            measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
        let m1 = MusicalAnchor(
            measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
        let a0 = DrawingAnchor(kind: .musical(m0), encodedDrawing: Data())
        let a1 = DrawingAnchor(kind: .musical(m1), encodedDrawing: Data())

        let split = AnnotationAnchoringCore.partitionByPage(
            [a0, a1], using: resolver, pageStartY: p0.y - 1, pageEndY: p0.y + 1,
        )
        #expect(split.onPage.count + split.offPage.count == 2)

        let none = AnnotationAnchoringCore.partitionByPage(
            [a0, a1], using: resolver, pageStartY: 1_000_000, pageEndY: 2_000_000,
        )
        #expect(none.onPage.isEmpty)
        #expect(none.offPage.count == 2)
    }
}
