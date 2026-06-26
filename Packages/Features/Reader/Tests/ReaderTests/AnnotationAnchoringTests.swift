import CoreGraphics
import Domain
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
}
