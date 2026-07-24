import Domain
import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Platform-neutral partial-eraser geometry, the sibling of `AnnotationAnchoringCore`. Operates on the same shared
// `InkStroke` / `DrawingAnchor` primitives — NO PencilKit, NO `LayoutDocument` — so it cross-compiles for the Apple
// and Android toolchains and is the single source of truth both platforms call. The hit test runs in DISPLAY space
// (after `place()`), because that is where the user's eraser gesture and the stroke's on-screen thickness both live;
// the surviving geometry is then sliced out of the STORED (anchor-relative) stroke, never the placed copy, so
// re-normalizing already-placed coordinates can't introduce round-trip error into what gets persisted.

/// The outcome of one `erase` call. `drawings` is the caller's full annotation layer with the eraser applied:
/// untouched drawings pass through by value, fully-erased ones are simply absent, and a split stroke contributes one
/// entry per surviving fragment. `changedIndices` are positions INTO `drawings` (the output), not into the caller's
/// input array — a split turns one input drawing into several output rows, and the caller (persistence / undo) needs
/// to know which of those output rows are new writes versus untouched carry-overs.
public struct EraseResult: Sendable {
    public let drawings: [DrawingAnchor]
    public let changedIndices: [Int]

    public init(drawings: [DrawingAnchor], changedIndices: [Int]) {
        self.drawings = drawings
        self.changedIndices = changedIndices
    }
}

public enum AnnotationEraseCore {
    /// Erases the eraser `path` (a display-space polyline, mm) from every stroke in `drawings`. `transforms` is
    /// positionally aligned with `drawings` (the same shape `AnnotationAnchoringCore.display` returns); a `nil`
    /// entry — an anchor that can't currently place — passes that drawing through untouched, exactly like a miss.
    public static func erase(
        _ drawings: [DrawingAnchor],
        transforms: [StrokeTransform?],
        path: [CGPoint],
        radiusMm: CGFloat,
    ) -> EraseResult {
        let eraser = eraserSegments(path)
        var outDrawings: [DrawingAnchor] = []
        outDrawings.reserveCapacity(drawings.count)
        var changedIndices: [Int] = []

        for (index, drawing) in drawings.enumerated() {
            guard index < transforms.count, let transform = transforms[index],
                  let stored = try? InkStrokeCodec.decode(drawing.encodedDrawing)
            else {
                outDrawings.append(drawing)
                continue
            }

            switch eraseStroke(stored, transform: transform, eraser: eraser, radiusMm: radiusMm) {
            case .unchanged:
                outDrawings.append(drawing)
            case .dropped:
                break
            case let .fragments(strokes):
                for stroke in strokes {
                    let fragment = DrawingAnchor(kind: drawing.kind, encodedDrawing: InkStrokeCodec.encode(stroke))
                    outDrawings.append(fragment)
                    changedIndices.append(outDrawings.count - 1)
                }
            }
        }

        return EraseResult(drawings: outDrawings, changedIndices: changedIndices)
    }

    // MARK: - Per-stroke erase

    private enum StrokeOutcome {
        case unchanged
        case dropped
        case fragments([InkStroke])
    }

    /// Places `stored` into display space to hit-test it against `eraser`, then slices survivor runs out of `stored`
    /// itself — exactly what `AnnotationAnchoringCore.capture` would have produced had the user drawn each surviving
    /// fragment separately.
    private static func eraseStroke(
        _ stored: InkStroke, transform: StrokeTransform, eraser: [(CGPoint, CGPoint)], radiusMm: CGFloat,
    ) -> StrokeOutcome {
        let placed = AnnotationAnchoringCore.place(stored, with: transform)
        let count = placed.x.count

        // A stroke with fewer than two samples has no segments to hit-test; the whole stroke lives or dies on
        // whether its single point falls in range.
        guard count >= 2 else {
            guard count == 1 else { return .unchanged }
            let point = CGPoint(x: CGFloat(placed.x[0]), y: CGFloat(placed.y[0]))
            let halfWidth = CGFloat(max(placed.width[0], placed.baseWidthSp)) / 2
            let erased = isErased(point, point, halfWidth: halfWidth, eraser: eraser, radiusMm: radiusMm)
            return erased ? .dropped : .unchanged
        }

        // One boolean per SEGMENT (a consecutive sample pair), not per sample: a segment between two sparse samples
        // must still be cut when the eraser crosses its middle, even though neither endpoint sits inside the eraser.
        var segmentSurvives = [Bool](repeating: true, count: count - 1)
        for i in 0 ..< count - 1 {
            let a = CGPoint(x: CGFloat(placed.x[i]), y: CGFloat(placed.y[i]))
            let b = CGPoint(x: CGFloat(placed.x[i + 1]), y: CGFloat(placed.y[i + 1]))
            let halfWidth = CGFloat(max(max(placed.width[i], placed.width[i + 1]), placed.baseWidthSp)) / 2
            segmentSurvives[i] = !isErased(a, b, halfWidth: halfWidth, eraser: eraser, radiusMm: radiusMm)
        }

        // A sample survives if EITHER adjacent segment survives, so one erased neighbor doesn't sever a sample the
        // other side still wants to keep. The first/last sample has only one neighbor.
        var sampleSurvives = [Bool](repeating: true, count: count)
        for j in 0 ..< count {
            let left = j > 0 ? segmentSurvives[j - 1] : false
            let right = j < count - 1 ? segmentSurvives[j] : false
            sampleSurvives[j] = left || right
        }

        let runs = survivorRuns(sampleSurvives)
        if runs.count == 1, runs[0] == 0 ... (count - 1) {
            return .unchanged // nothing was actually erased
        }
        guard !runs.isEmpty else { return .dropped }
        return .fragments(runs.map { slice(stored, range: $0) })
    }

    /// Maximal contiguous spans of surviving samples, each at least 2 samples long. A lone surviving sample has no
    /// segment left to render it with — PencilKit / androidx.ink both draw segments, not points — so it is dropped
    /// along with the erased segments around it.
    private static func survivorRuns(_ survives: [Bool]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for (i, ok) in survives.enumerated() {
            if ok {
                if start == nil { start = i }
            } else if let s = start {
                if i - 1 > s { runs.append(s ... (i - 1)) }
                start = nil
            }
        }
        if let s = start, survives.count - 1 > s {
            runs.append(s ... (survives.count - 1))
        }
        return runs
    }

    // MARK: - Hit test

    /// True when a stroke segment `a`–`b`, expanded by `halfWidth`, comes within `radiusMm` of any segment of the
    /// eraser polyline.
    private static func isErased(
        _ a: CGPoint, _ b: CGPoint, halfWidth: CGFloat, eraser: [(CGPoint, CGPoint)], radiusMm: CGFloat,
    ) -> Bool {
        guard !eraser.isEmpty else { return false }
        let threshold = radiusMm + halfWidth
        return eraser.contains { distanceSegmentToSegment(a, b, $0.0, $0.1) <= threshold }
    }

    /// The eraser `path` as consecutive segments. A single-point path becomes one degenerate (zero-length) segment,
    /// so a tap-to-erase gesture still hit-tests via the same segment-to-segment machinery as a drag.
    private static func eraserSegments(_ path: [CGPoint]) -> [(CGPoint, CGPoint)] {
        guard let first = path.first else { return [] }
        guard path.count > 1 else { return [(first, first)] }
        return Array(zip(path, path.dropFirst()))
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Minimum distance from `p` to the segment `a`–`b`, clamping the projection to the segment's extent. A
    /// degenerate (zero-length) segment falls back to a plain point-to-point distance.
    private static func distancePointToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        guard lengthSquared > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSquared))
        return distance(p, CGPoint(x: a.x + t * abx, y: a.y + t * aby))
    }

    /// Standard 2D segment-to-segment distance: zero when the segments cross (including a degenerate segment
    /// landing exactly on the other), otherwise the smallest of the four endpoint-to-opposite-segment distances.
    private static func distanceSegmentToSegment(
        _ a1: CGPoint, _ a2: CGPoint, _ b1: CGPoint, _ b2: CGPoint,
    ) -> CGFloat {
        if segmentsIntersect(a1, a2, b1, b2) { return 0 }
        return min(
            min(distancePointToSegment(a1, b1, b2), distancePointToSegment(a2, b1, b2)),
            min(distancePointToSegment(b1, a1, a2), distancePointToSegment(b2, a1, a2)),
        )
    }

    /// Orientation-based segment intersection test (the collinear-overlap case is handled by the `onSegment`
    /// bounding-box check), used only to detect the zero-distance case above.
    private static func segmentsIntersect(_ a1: CGPoint, _ a2: CGPoint, _ b1: CGPoint, _ b2: CGPoint) -> Bool {
        func orientation(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Int {
            let val = (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
            if val == 0 { return 0 }
            return val > 0 ? 1 : 2
        }
        func onSegment(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Bool {
            min(p.x, r.x) <= q.x && q.x <= max(p.x, r.x) && min(p.y, r.y) <= q.y && q.y <= max(p.y, r.y)
        }
        let o1 = orientation(a1, a2, b1)
        let o2 = orientation(a1, a2, b2)
        let o3 = orientation(b1, b2, a1)
        let o4 = orientation(b1, b2, a2)
        if o1 != o2, o3 != o4 { return true }
        if o1 == 0, onSegment(a1, b1, a2) { return true }
        if o2 == 0, onSegment(a1, b2, a2) { return true }
        if o3 == 0, onSegment(b1, a1, b2) { return true }
        if o4 == 0, onSegment(b1, a2, b2) { return true }
        return false
    }

    // MARK: - Fragment slicing

    /// Slices `stroke` (the STORED anchor-relative geometry, not the placed copy) to `range`. Optional per-sample
    /// channels are sliced only when the source has them — an empty channel stays empty, matching the
    /// structure-of-arrays invariant `InkStroke` documents.
    private static func slice(_ stroke: InkStroke, range: ClosedRange<Int>) -> InkStroke {
        var out = stroke
        out.x = Array(stroke.x[range])
        out.y = Array(stroke.y[range])
        out.width = Array(stroke.width[range])
        if !stroke.force.isEmpty { out.force = Array(stroke.force[range]) }
        if !stroke.azimuth.isEmpty { out.azimuth = Array(stroke.azimuth[range]) }
        if !stroke.altitude.isEmpty { out.altitude = Array(stroke.altitude[range]) }
        if !stroke.timeMillis.isEmpty { out.timeMillis = Array(stroke.timeMillis[range]) }
        return out
    }
}
