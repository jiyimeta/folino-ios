import CoreGraphics
import Domain
import PencilKit
@testable import Reader
import SheetMusicCore
import SheetMusicLayout
import Testing

@Suite("AnnotationAnchoring")
struct AnnotationAnchoringTests {
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

    @Test
    func `anchorPoint composes the forward reference with the anchor's sp offsets`() throws {
        let d = doc()
        let anchor = MusicalAnchor(
            measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
            dxSp: 1.5, verticalOffsetSp: -2.0,
        )
        let ref = try #require(
            d.anchorReferencePoint(measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0),
        )
        let p = try #require(AnnotationAnchoring.anchorPoint(for: anchor, in: d))
        #expect(abs(p.point.x - (ref.point.x + 1.5 * ref.sp)) < 0.001)
        #expect(abs(p.point.y - (ref.point.y - 2.0 * ref.sp)) < 0.001)
        #expect(p.sp == ref.sp)
    }

    @Test
    func `normalize then display transform is identity at the same layout`() throws {
        let d = doc()
        let centroid = try #require(
            d.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0)?.point,
        )
        let (anchor, normalize) = try #require(AnnotationAnchoring.normalizeTransform(forCentroid: centroid, in: d))
        let display = try #require(AnnotationAnchoring.displayTransform(for: anchor, in: d))
        let round = normalize.concatenating(display)
        // a sample document point maps back to itself
        let sample = CGPoint(x: centroid.x + 30, y: centroid.y - 12)
        let mapped = sample.applying(round)
        #expect(abs(mapped.x - sample.x) < 0.01)
        #expect(abs(mapped.y - sample.y) < 0.01)
    }

    @Test
    func `staff-size doubling doubles the display scale`() throws {
        let small = doc(staffSize: 20)
        let large = doc(staffSize: 40)
        let centroid = try #require(
            small.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0)?.point,
        )
        let (anchor, _) = try #require(AnnotationAnchoring.normalizeTransform(forCentroid: centroid, in: small))
        let dSmall = try #require(AnnotationAnchoring.displayTransform(for: anchor, in: small))
        let dLarge = try #require(AnnotationAnchoring.displayTransform(for: anchor, in: large))
        // scale component a doubles (sp 5 -> 10)
        #expect(abs(dLarge.a - 2 * dSmall.a) < 0.001)
    }

    /// A natural-width (no-wrap) layout of the same score, as Horizontal mode builds it. Proves an anchor captured in
    /// one layout projects into a different layout — the cross-mode sharing guarantee (Vertical ink shows in
    /// Horizontal).
    private func naturalDoc(staffSize: CGFloat = 28) -> LayoutDocument {
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
        options.wrapToViewWidth = false
        options.includeTitleFrame = false
        let natural = LayoutEngine.naturalContentWidth(score: score, options: options)
        return LayoutEngine.layout(score: score, options: options, availableWidth: natural)
    }

    @Test
    func `anchor captured in a wrap layout resolves in a natural-width layout`() throws {
        let wrap = doc()
        let natural = naturalDoc()
        let centroid = try #require(
            wrap.anchorReferencePoint(measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0)?.point,
        )
        let (anchor, _) = try #require(AnnotationAnchoring.normalizeTransform(forCentroid: centroid, in: wrap))
        // The same musical anchor resolves to a concrete point in the natural-width layout (non-nil display transform).
        #expect(AnnotationAnchoring.displayTransform(for: anchor, in: natural) != nil)
    }

    @Test
    func `partitionByPage splits anchors by resolved y-band`() throws {
        let d = doc()
        // Two anchors: one on measure 0, one on measure 1. Resolve their points to pick a split band.
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
        // Band covering p0.y only (single-system layout => both share a y; widen band to include both,
        // then a zero-height band to exclude).
        let all = AnnotationAnchoring.partitionByPage([a0, a1], in: d, pageStartY: p0.y - 1, pageEndY: p0.y + 1)
        #expect(all.onPage.count + all.offPage.count == 2)
        // A band strictly below every anchor puts all of them off-page; none are dropped.
        let none = AnnotationAnchoring.partitionByPage([a0, a1], in: d, pageStartY: 1_000_000, pageEndY: 2_000_000)
        #expect(none.onPage.isEmpty)
        #expect(none.offPage.count == 2)
    }

    @Test
    func `capturePaged then displayPaged round-trips a band-space stroke`() throws {
        let d = doc()
        let pageStartY: CGFloat = 0
        let contentPadding: CGFloat = 12
        // A stroke sitting on the first staff, expressed in band space (doc point + padding, minus pageStartY).
        let docPoint = try #require(
            d.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0)?.point,
        )
        let bandPoint = CGPoint(x: docPoint.x + contentPadding, y: docPoint.y - pageStartY)
        let stroke = PaintTestSupport.dot(at: bandPoint)
        let captured = AnnotationAnchoring.capturePaged(
            strokes: [stroke], in: d, pageStartY: pageStartY, contentPadding: contentPadding,
        )
        #expect(captured.count == 1)
        let pageEndY = d.size.height
        let shown = AnnotationAnchoring.displayPaged(
            captured, in: d, pageStartY: pageStartY, pageEndY: pageEndY, contentPadding: contentPadding,
        )
        let outPoint = try #require(shown.strokes.first?.renderBounds.center)
        #expect(abs(outPoint.x - bandPoint.x) < 1.0)
        #expect(abs(outPoint.y - bandPoint.y) < 1.0)
    }

    @Test
    func `displayPaged skips anchors off the page band`() throws {
        let d = doc()
        let docPoint = try #require(
            d.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0)?.point,
        )
        let stroke = PaintTestSupport.dot(at: CGPoint(x: docPoint.x + 12, y: docPoint.y))
        let captured = AnnotationAnchoring.capturePaged(strokes: [stroke], in: d, pageStartY: 0, contentPadding: 12)
        // A band far below the stroke yields no displayed strokes.
        let shown = AnnotationAnchoring.displayPaged(
            captured, in: d, pageStartY: 1_000_000, pageEndY: 2_000_000, contentPadding: 12,
        )
        #expect(shown.strokes.isEmpty)
    }
}
