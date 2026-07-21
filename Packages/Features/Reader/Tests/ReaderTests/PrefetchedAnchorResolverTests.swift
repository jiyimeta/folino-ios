import Domain
import Foundation
import ReaderAnnotationCore
import Testing

#if canImport(CoreGraphics)
import CoreGraphics
#endif

@Suite("PrefetchedAnchorResolver")
struct PrefetchedAnchorResolverTests {
    private func stroke(x: [Float], y: [Float]) -> InkStroke {
        InkStroke(
            tool: .pen, colorRGBA: 0x0000_00FF, baseWidthSp: 1, opacity: 1,
            x: x, y: y, width: Array(repeating: 1, count: x.count),
            force: [], azimuth: [], altitude: [], timeMillis: [],
        )
    }

    @Test
    func `capture through a prefetched resolver anchors the stroke and normalizes geometry`() throws {
        let anchor = MusicalAnchor(
            measureIndex: 1, tickInMeasure: 0, partIndex: 0,
            staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
        let refPoint = CGPoint(x: 100, y: 200)
        let sp: CGFloat = 4
        let resolver = PrefetchedAnchorResolver(
            resolvedAnchor: anchor, referencePoints: [anchor: (refPoint, sp)],
        )

        // A stroke whose bbox center is the reference point (rep point == anchor point P for a zero-offset anchor).
        let s = stroke(x: [96, 104], y: [200, 200])
        let drawings = AnnotationAnchoringCore.capture(strokes: [s], using: resolver)
        #expect(drawings.count == 1)
        guard case let .musical(a) = drawings[0].kind else {
            Issue.record("expected a musical anchor")
            return
        }
        #expect(a == anchor)

        // Round-trip: display at the same layout must place the geometry back at P.
        let placed = AnnotationAnchoringCore.display(drawings, using: resolver)
        let t = try #require(placed[0])
        #expect(abs(t.px - refPoint.x) < 0.001)
        #expect(abs(t.py - refPoint.y) < 0.001)
        #expect(abs(t.sp - sp) < 0.001)
    }

    @Test
    func `a missing reference point drops the stroke on capture`() {
        let anchor = MusicalAnchor(
            measureIndex: 9, tickInMeasure: 0, partIndex: 0,
            staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
        let resolver = PrefetchedAnchorResolver(resolvedAnchor: anchor, referencePoints: [:])
        let s = stroke(x: [0, 10], y: [0, 0])
        #expect(AnnotationAnchoringCore.capture(strokes: [s], using: resolver).isEmpty)
    }

    @Test
    func `display yields a nil transform for an anchor with no prefetched reference point`() {
        let anchor = MusicalAnchor(
            measureIndex: 2, tickInMeasure: 240, partIndex: 0,
            staffIndexInPart: 0, dxSp: 1, verticalOffsetSp: -1,
        )
        let drawing = DrawingAnchor(
            kind: .musical(anchor),
            encodedDrawing: InkStrokeCodec.encode(stroke(x: [0, 1], y: [0, 1])),
        )
        let resolver = PrefetchedAnchorResolver(resolvedAnchor: nil, referencePoints: [:])
        let transforms = AnnotationAnchoringCore.display([drawing], using: resolver)
        #expect(transforms.count == 1)
        #expect(transforms[0] == nil)
    }
}
