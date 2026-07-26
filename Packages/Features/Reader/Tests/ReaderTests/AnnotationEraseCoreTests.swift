import Domain
import Foundation
import ReaderAnnotationCore
import Testing

@Suite("AnnotationEraseCore")
struct AnnotationEraseCoreTests {
    /// Anchor-relative stroke from document-mm samples. With an identity transform (sp 1, p 0) the
    /// stored geometry IS the document geometry, so tests can reason in document-mm directly.
    private func drawing(_ points: [(Float, Float)], baseWidth: Float = 0.5) -> DrawingAnchor {
        let stroke = InkStroke(
            tool: .pen, colorRGBA: 0x0000_00FF, baseWidthSp: baseWidth, opacity: 1,
            x: points.map(\.0), y: points.map(\.1), width: points.map { _ in 0 },
            force: [], azimuth: [], altitude: [], timeMillis: [],
        )
        return DrawingAnchor(
            kind: .musical(MusicalAnchor(
                measureIndex: 0,
                tickInMeasure: 0,
                partIndex: 0,
                staffIndexInPart: 0,
                dxSp: 0,
                verticalOffsetSp: 0,
            )),
            encodedDrawing: InkStrokeCodec.encode(stroke),
        )
    }

    private let identity = StrokeTransform(sp: 1, px: 0, py: 0)

    /// `InkStrokeCodec.decode` is throwing (see `InkStrokeCodecTests`), not the optional-returning API the brief's
    /// helper assumed — kept throwing here too so a decode failure surfaces as a normal Swift Testing failure rather
    /// than a force-unwrap trap, matching how `AnnotationAnchoringCoreTests` calls the same decoder.
    private func decoded(_ d: DrawingAnchor) throws -> InkStroke {
        try InkStrokeCodec.decode(d.encodedDrawing)
    }

    @Test
    func `a miss leaves the layer untouched`() throws {
        let layer = [drawing([(0, 0), (10, 0)])]
        let out = AnnotationEraseCore.erase(
            layer,
            transforms: [identity],
            path: [CGPoint(x: 5, y: 50)],
            radiusMm: 1,
        )
        #expect(out.changedIndices.isEmpty)
        #expect(out.drawings.count == 1)
        #expect(try decoded(out.drawings[0]).x == decoded(layer[0]).x)
    }

    @Test
    func `erasing the middle yields two fragments`() throws {
        let layer = [drawing([(0, 0), (2, 0), (4, 0), (6, 0), (8, 0), (10, 0)])]
        let out = AnnotationEraseCore.erase(
            layer,
            transforms: [identity],
            path: [CGPoint(x: 5, y: 0)],
            radiusMm: 1.2,
        )
        #expect(out.drawings.count == 2)
        #expect(out.changedIndices.sorted() == [0, 1])
        #expect(try decoded(out.drawings[0]).x.allSatisfy { $0 < 5 })
        #expect(try decoded(out.drawings[1]).x.allSatisfy { $0 > 5 })
    }

    @Test
    func `covering the whole stroke drops it`() {
        let layer = [drawing([(0, 0), (1, 0), (2, 0)])]
        let out = AnnotationEraseCore.erase(
            layer,
            transforms: [identity],
            path: [CGPoint(x: 1, y: 0)],
            radiusMm: 10,
        )
        #expect(out.drawings.isEmpty)
        #expect(out.changedIndices.isEmpty)
    }

    @Test
    func `single-point remnants are discarded`() {
        // Erasing everything but the last sample leaves a 1-point run, which must not survive.
        let layer = [drawing([(0, 0), (1, 0), (2, 0), (20, 0)])]
        let out = AnnotationEraseCore.erase(
            layer,
            transforms: [identity],
            path: [CGPoint(x: 1, y: 0)],
            radiusMm: 5,
        )
        #expect(out.drawings.isEmpty)
    }

    @Test
    func `an eraser crossing between two distant samples still cuts`() {
        // Samples 20mm apart; the eraser crosses the middle and touches neither endpoint.
        let layer = [drawing([(0, 0), (20, 0)])]
        let out = AnnotationEraseCore.erase(
            layer,
            transforms: [identity],
            path: [CGPoint(x: 10, y: -5), CGPoint(x: 10, y: 5)],
            radiusMm: 1,
        )
        #expect(out.drawings.isEmpty) // both samples' only segment is erased
        #expect(out.changedIndices.isEmpty)
    }

    @Test
    func `thickness widens the hit test`() {
        // Centreline is 3mm away; radius 1 alone misses, but baseWidth 5 (half = 2.5) reaches it.
        let thin = [drawing([(0, 0), (10, 0)], baseWidth: 0.5)]
        let thick = [drawing([(0, 0), (10, 0)], baseWidth: 5)]
        let path = [CGPoint(x: 5, y: 3)]
        #expect(
            AnnotationEraseCore.erase(thin, transforms: [identity], path: path, radiusMm: 1)
                .changedIndices.isEmpty,
        )
        #expect(
            AnnotationEraseCore.erase(thick, transforms: [identity], path: path, radiusMm: 1)
                .drawings.isEmpty,
        )
    }

    @Test
    func `an unresolved drawing passes through untouched`() {
        let layer = [drawing([(0, 0), (10, 0)])]
        let out = AnnotationEraseCore.erase(
            layer,
            transforms: [nil],
            path: [CGPoint(x: 5, y: 0)],
            radiusMm: 10,
        )
        #expect(out.drawings.count == 1)
        #expect(out.changedIndices.isEmpty)
    }

    @Test
    func `absent optional channels stay absent, present ones stay aligned`() throws {
        let layer = [drawing([(0, 0), (2, 0), (4, 0), (6, 0), (8, 0), (10, 0)])]
        let out = AnnotationEraseCore.erase(
            layer,
            transforms: [identity],
            path: [CGPoint(x: 5, y: 0)],
            radiusMm: 1.2,
        )
        for d in out.drawings {
            let s = try decoded(d)
            #expect(s.y.count == s.x.count)
            #expect(s.width.count == s.x.count)
            #expect(s.force.isEmpty)
            #expect(s.azimuth.isEmpty)
            #expect(s.altitude.isEmpty)
        }
    }
}
