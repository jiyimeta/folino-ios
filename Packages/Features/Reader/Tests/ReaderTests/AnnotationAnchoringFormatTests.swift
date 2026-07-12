import CoreGraphics
import Domain
import PencilKit
@testable import Reader
import SheetMusicCore
import SheetMusicLayout
import Testing

@Suite("AnnotationAnchoring format")
struct AnnotationAnchoringFormatTests {
    private let _install: Void = LayoutTestSupport.installed

    private func doc(staffSize: CGFloat = 28) -> LayoutDocument {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure, measure])
        let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])
        var options = ScoreViewOptions()
        options.staffSize = staffSize
        return LayoutEngine.layout(score: score, options: options, availableWidth: 800)
    }

    private func strokeNear(_ p: CGPoint) -> PKStroke {
        let pts = (0 ..< 5).map { i in
            PKStrokePoint(
                location: CGPoint(x: p.x + CGFloat(i), y: p.y),
                timeOffset: Double(i) * 0.01,
                size: CGSize(width: 2, height: 2),
                opacity: 1,
                force: 0.5,
                azimuth: 0,
                altitude: .pi / 2,
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: 0)),
        )
    }

    @Test func `capture emits neutral bytes`() throws {
        let d = doc()
        let ref = try #require(
            d.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0),
        )
        let anchors = AnnotationAnchoring.capture(strokes: [strokeNear(ref.point)], in: d)
        #expect(anchors.count == 1)
        #expect(InkStrokeCodec.isInkStroke(anchors[0].encodedDrawing))
    }

    @Test func `display reads both formats`() throws {
        let d = doc()
        let ref = try #require(
            d.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0),
        )
        let neutralAnchors = AnnotationAnchoring.capture(strokes: [strokeNear(ref.point)], in: d)
        #expect(!neutralAnchors.isEmpty)
        #expect(!AnnotationAnchoring.display(neutralAnchors, in: d).strokes.isEmpty)

        // The same anchor re-encoded in the legacy PKDrawing format also renders (read-both).
        let legacy = try neutralAnchors.map { anchor -> DrawingAnchor in
            let pk = try #require(InkStrokePencilKitBridge.decodeStoredDrawing(anchor.encodedDrawing))
            return DrawingAnchor(id: anchor.id, kind: anchor.kind, encodedDrawing: pk.dataRepresentation())
        }
        #expect(!AnnotationAnchoring.display(legacy, in: d).strokes.isEmpty)
    }

    @Test func `display bakes the projection into points, not the stroke transform`() throws {
        let d = doc()
        let ref = try #require(
            d.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0),
        )
        let anchors = AnnotationAnchoring.capture(strokes: [strokeNear(ref.point)], in: d)
        let projected = AnnotationAnchoring.display(anchors, in: d)
        let stroke = try #require(projected.strokes.first)
        let t = stroke.transform
        // PencilKit derives its renderable content extent from PATH BOUNDS and ignores a lingering per-stroke
        // transform, so a correct bake must leave `transform` at (approximately) identity — the projection must
        // already be folded into the control-point locations.
        #expect(abs(t.a - 1) < 0.001)
        #expect(abs(t.b) < 0.001)
        #expect(abs(t.c) < 0.001)
        #expect(abs(t.d - 1) < 0.001)
        #expect(abs(t.tx) < 0.001)
        #expect(abs(t.ty) < 0.001)
    }
}
