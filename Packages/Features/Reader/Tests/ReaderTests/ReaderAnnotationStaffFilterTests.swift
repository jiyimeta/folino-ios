import CoreGraphics
import Domain
import PencilKit
@testable import Reader
import SheetMusicCore
import SheetMusicLayout
import Testing

/// Ink vs. the hidden-staves DISPLAY filter. Nothing here persists anything: every case is "the stored layer is these
/// bytes, the reader is hiding this staff — what should be on screen, and what should a capture write back".
///
/// The score is three single-staff parts, hiding part 1. `filtered(hidingStaves:)` therefore renumbers source part 2
/// to display part 1, which is the whole trap: an anchor stamped `partIndex: 2` resolves against nothing (or, worse,
/// against a different instrument) in a document that only has two parts.
@Suite("Annotation ink vs. hidden staves")
struct ReaderAnnotationStaffFilterTests {
    /// Install the CoreText FontMetrics provider so LayoutEngine's precondition passes.
    private let _install: Void = LayoutTestSupport.installed

    private static let hiddenStaff = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    /// A score whose parts have the given staff counts — `[1, 1, 1]` for the three-soloist default, `[1, 2, 1]` for
    /// the grand-staff case.
    private func source(staffCounts: [Int] = [1, 1, 1]) -> Score {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure, measure])
        return Score(
            division: 480,
            parts: staffCounts.enumerated().map { index, staves in
                Part(
                    id: "\(index + 1)", instrument: Instrument(id: "x\(index)"),
                    staves: Array(repeating: staff, count: staves),
                )
            },
        )
    }

    private func doc(_ score: Score) -> LayoutDocument {
        var options = ScoreViewOptions()
        options.staffSize = 28
        return LayoutEngine.layout(score: score, options: options, availableWidth: 800)
    }

    /// The stored layer as it exists on disk: captured against the FULL score, so its anchors are in source
    /// addressing — exactly what a user who inked before hiding anything would have.
    private func storedInk(on address: StaffAddress, in score: Score) throws -> [DrawingAnchor] {
        let full = doc(score)
        let point = try #require(full.anchorReferencePoint(
            measureIndex: 0, tickInMeasure: 0,
            partIndex: address.partIndex, staffIndexInPart: address.staffIndexInPart,
        )).point
        let captured = AnnotationAnchoring.capture(strokes: [PaintTestSupport.dot(at: point)], in: full)
        #expect(captured.count == 1)
        return captured
    }

    private func filter(for score: Score, hiding hidden: Set<StaffAddress>) -> AnnotationStaffFilter {
        AnnotationStaffFilter(sourceScore: score, hiddenStaves: hidden)
    }

    @Test
    func `ink on a hidden staff is not drawn, and comes back when the staff is shown`() throws {
        let score = source()
        let ink = try storedInk(on: Self.hiddenStaff, in: score)
        let hidden: Set<StaffAddress> = [Self.hiddenStaff]
        let filtered = doc(score.filtered(hidingStaves: hidden))

        // Hidden: nothing on screen.
        let whileHidden = AnnotationAnchoring.display(
            ink, in: filtered, staffFilter: filter(for: score, hiding: hidden),
        )
        #expect(whileHidden.strokes.isEmpty)

        // The bug this closes: unfiltered, `partIndex: 1` still resolves in the two-part document — as the OTHER
        // instrument's staff — so the stroke kept being drawn, on the wrong system.
        #expect(!AnnotationAnchoring.display(ink, in: filtered).strokes.isEmpty)

        // Shown again: the stored layer was never touched, so the same bytes project as before.
        #expect(!AnnotationAnchoring.display(ink, in: doc(score)).strokes.isEmpty)
    }

    @Test
    func `ink on a visible staff follows the hiding renumbering`() throws {
        let score = source()
        let onLowerStaff = StaffAddress(partIndex: 2, staffIndexInPart: 0)
        let ink = try storedInk(on: onLowerStaff, in: score)
        let hidden: Set<StaffAddress> = [Self.hiddenStaff]
        let filtered = doc(score.filtered(hidingStaves: hidden))
        // Source part 2 is display part 1 once part 1 is hidden.
        let expected = try #require(filtered.anchorReferencePoint(
            measureIndex: 0, tickInMeasure: 0, partIndex: 1, staffIndexInPart: 0,
        )).point

        let shown = AnnotationAnchoring.display(ink, in: filtered, staffFilter: filter(for: score, hiding: hidden))
        let placed = try #require(shown.strokes.first?.renderBounds.center)
        #expect(abs(placed.x - expected.x) < 1.0)
        #expect(abs(placed.y - expected.y) < 1.0)

        // Unfiltered, source part 2 has no counterpart in the two-part document, so the stroke vanished entirely.
        #expect(AnnotationAnchoring.display(ink, in: filtered).strokes.isEmpty)
    }

    @Test
    func `a capture taken while a staff is hidden is stamped in source addressing`() throws {
        let score = source()
        let hidden: Set<StaffAddress> = [Self.hiddenStaff]
        let filtered = doc(score.filtered(hidingStaves: hidden))
        // Draw on what the reader shows as the second system — source part 2.
        let target = try #require(filtered.anchorReferencePoint(
            measureIndex: 0, tickInMeasure: 0, partIndex: 1, staffIndexInPart: 0,
        )).point

        let captured = AnnotationAnchoring.capture(
            strokes: [PaintTestSupport.dot(at: target)], in: filtered,
            staffFilter: filter(for: score, hiding: hidden),
        )
        guard case let .musical(anchor) = try #require(captured.first).kind else {
            Issue.record("expected a musical anchor")
            return
        }
        #expect(anchor.partIndex == 2)
        #expect(anchor.staffIndexInPart == 0)

        // The corruption this closes: without the translation the document answers in its OWN numbering, and that
        // display-space index would have been written into the stored layer, unrecoverably.
        let unfiltered = AnnotationAnchoring.capture(strokes: [PaintTestSupport.dot(at: target)], in: filtered)
        guard case let .musical(wrong) = try #require(unfiltered.first).kind else {
            Issue.record("expected a musical anchor")
            return
        }
        #expect(wrong.partIndex == 1)
    }

    /// The anchor — the part of a `DrawingAnchor` this fix is about — has to survive a capture → display → capture
    /// cycle unchanged. The stroke BYTES do not, and never did: `place` bakes the layout transform into `Float`
    /// coordinates and `normalized` divides it back out, so the last bits move by a hair on every round trip. That is
    /// the neutral pipeline's pre-existing behavior, unrelated to staff hiding; what matters here is that the source
    /// addressing does not drift, and that the ink stays where it was drawn.
    @Test
    func `capture round-trips a stable source anchor while a staff is hidden`() throws {
        let score = source()
        let hidden: Set<StaffAddress> = [Self.hiddenStaff]
        let staffFilter = filter(for: score, hiding: hidden)
        let filtered = doc(score.filtered(hidingStaves: hidden))
        let target = try #require(filtered.anchorReferencePoint(
            measureIndex: 0, tickInMeasure: 0, partIndex: 1, staffIndexInPart: 0,
        )).point

        let first = AnnotationAnchoring.capture(
            strokes: [PaintTestSupport.dot(at: target)], in: filtered, staffFilter: staffFilter,
        )
        // Project it back onto the same layout and re-capture, the way a reflow / reseed echo does.
        let shown = AnnotationAnchoring.display(first, in: filtered, staffFilter: staffFilter)
        let second = AnnotationAnchoring.capture(strokes: shown.strokes, in: filtered, staffFilter: staffFilter)
        // `id` is minted fresh per capture by design; the anchor is what has to be stable — same source part / staff,
        // same measure / tick, same sp offsets, exactly.
        #expect(first.map(\.kind) == second.map(\.kind))
        // And the ink has not crept: re-projecting the second capture puts it back on the same pixel.
        let again = AnnotationAnchoring.display(second, in: filtered, staffFilter: staffFilter)
        let before = try #require(shown.strokes.first?.renderBounds.center)
        let after = try #require(again.strokes.first?.renderBounds.center)
        #expect(abs(after.x - before.x) < 0.01)
        #expect(abs(after.y - before.y) < 0.01)
        #expect(abs(before.x - target.x) < 1.0)
        #expect(abs(before.y - target.y) < 1.0)
    }

    @Test
    func `hidden ink is carried across a capture instead of being replaced away`() throws {
        let score = source()
        let hidden: Set<StaffAddress> = [Self.hiddenStaff]
        let staffFilter = filter(for: score, hiding: hidden)
        let onHidden = try storedInk(on: Self.hiddenStaff, in: score)
        let onVisible = try storedInk(on: StaffAddress(partIndex: 2, staffIndexInPart: 0), in: score)

        // What the vertical / horizontal containers must re-add: the strokes no canvas can show.
        #expect(staffFilter.hiddenAnchors(in: onHidden + onVisible).map(\.id) == onHidden.map(\.id))
    }

    @Test
    func `page anchors are untouched by the staff filter`() {
        let score = source()
        let staffFilter = filter(for: score, hiding: [Self.hiddenStaff])
        let page = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: Data())
        // Not a musical anchor, so it is neither hidden by the filter nor claimed as a hidden-staff carry-over.
        #expect(staffFilter.hiddenAnchors(in: [page]).isEmpty)
    }

    @Test
    func `nothing hidden means nothing to translate`() throws {
        let score = source()
        let staffFilter = filter(for: score, hiding: [])
        let address = StaffAddress(partIndex: 2, staffIndexInPart: 0)
        #expect(staffFilter.displayAddress(for: address) == address)
        #expect(staffFilter.sourceAddress(for: address) == address)
        let ink = try storedInk(on: address, in: score)
        #expect(staffFilter.hiddenAnchors(in: ink).isEmpty)
    }

    /// The line between "hidden, carry it" and "gone, let it be pruned". An anchor naming a staff the score no longer
    /// has does not resolve either — but it is not HIDDEN, and carrying it would resurrect it forever, since the
    /// prune-on-next-capture path is the only thing that ever drops it.
    @Test
    func `an anchor on a staff the score no longer has is not treated as hidden`() {
        let score = source()
        let stale = MusicalAnchor(
            measureIndex: 0, tickInMeasure: 0, partIndex: 9, staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
        let staffFilter = filter(for: score, hiding: [Self.hiddenStaff])
        // It fails to resolve, exactly like a hidden staff…
        #expect(staffFilter.displayAddress(for: stale.staffAddress) == nil)
        // …but it is not carried across a capture.
        let drawing = DrawingAnchor(kind: .musical(stale), encodedDrawing: Data())
        #expect(staffFilter.hiddenAnchors(in: [drawing]).isEmpty)
    }

    // MARK: - The composition the containers perform

    /// The exact expression the vertical and horizontal containers commit. Page-anchored ink survives untouched (only
    /// the `.score` rendition is replaced), hidden-staff ink comes through byte-identical, and the visible ink is the
    /// fresh capture.
    @Test
    func `replacing the score layer keeps page and hidden ink while swapping the visible ink`() throws {
        let score = source()
        let hidden: Set<StaffAddress> = [Self.hiddenStaff]
        let staffFilter = filter(for: score, hiding: hidden)
        let filtered = doc(score.filtered(hidingStaves: hidden))

        let onHidden = try storedInk(on: Self.hiddenStaff, in: score)
        let onVisible = try storedInk(on: StaffAddress(partIndex: 2, staffIndexInPart: 0), in: score)
        let page = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: Data([1, 2, 3]))
        let existing = [page] + onHidden + onVisible

        // The user draws one new stroke on the visible staff; the canvas holds only what is on screen.
        let target = try #require(filtered.anchorReferencePoint(
            measureIndex: 0, tickInMeasure: 0, partIndex: 1, staffIndexInPart: 0,
        )).point
        let captured = AnnotationAnchoring.capture(
            strokes: [PaintTestSupport.dot(at: target)], in: filtered, staffFilter: staffFilter,
        )
        let committed = AnnotationLayers.replacing(
            .score, in: existing,
            with: staffFilter.hiddenAnchors(in: existing) + captured,
        )

        // The PDF rendition's ink is untouched, bytes and all.
        #expect(committed.filter { $0.kind.rendition == .originalPDF } == [page])
        // The hidden staff's ink came through byte-identical — same id, same anchor, same bytes.
        #expect(committed.contains(where: { $0 == onHidden[0] }))
        // The old visible-staff stroke was replaced by the capture, not kept alongside it.
        #expect(!committed.contains(where: { $0.id == onVisible[0].id }))
        #expect(committed.count == 1 + onHidden.count + captured.count)
    }

    // MARK: - Renumbering inside a part

    /// A grand staff proves the staff index moves too, not just the part index. Parts are `[solo, grand(2), solo]`;
    /// hiding the FIRST part and the grand staff's TOP staff renumbers source `(1, 1)` to display `(0, 0)` — both
    /// components at once, which a single-staff fixture cannot show.
    @Test
    func `renumbering moves the staff index within a part, not only the part index`() throws {
        let score = source(staffCounts: [1, 2, 1])
        let hidden: Set<StaffAddress> = [
            StaffAddress(partIndex: 0, staffIndexInPart: 0),
            StaffAddress(partIndex: 1, staffIndexInPart: 0),
        ]
        let staffFilter = filter(for: score, hiding: hidden)
        let lowerHalf = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        #expect(staffFilter.displayAddress(for: lowerHalf) == StaffAddress(partIndex: 0, staffIndexInPart: 0))
        #expect(staffFilter.sourceAddress(for: StaffAddress(partIndex: 0, staffIndexInPart: 0)) == lowerHalf)

        let filtered = doc(score.filtered(hidingStaves: hidden))
        let expected = try #require(filtered.anchorReferencePoint(
            measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
        )).point

        // Display: ink stored on the grand staff's lower half lands on it, at its new address.
        let ink = try storedInk(on: lowerHalf, in: score)
        let placed = try #require(
            AnnotationAnchoring.display(ink, in: filtered, staffFilter: staffFilter).strokes.first?.renderBounds.center,
        )
        #expect(abs(placed.x - expected.x) < 1.0)
        #expect(abs(placed.y - expected.y) < 1.0)

        // Capture: drawing there writes back the grand staff's own (1, 1), not the document's (0, 0).
        let captured = AnnotationAnchoring.capture(
            strokes: [PaintTestSupport.dot(at: expected)], in: filtered, staffFilter: staffFilter,
        )
        guard case let .musical(anchor) = try #require(captured.first).kind else {
            Issue.record("expected a musical anchor")
            return
        }
        #expect(anchor.staffAddress == lowerHalf)

        // The hidden top half of the same part is neither drawn nor lost.
        let onTopHalf = try storedInk(on: StaffAddress(partIndex: 1, staffIndexInPart: 0), in: score)
        #expect(AnnotationAnchoring.display(onTopHalf, in: filtered, staffFilter: staffFilter).strokes.isEmpty)
        #expect(staffFilter.hiddenAnchors(in: onTopHalf).map(\.id) == onTopHalf.map(\.id))
    }
}
