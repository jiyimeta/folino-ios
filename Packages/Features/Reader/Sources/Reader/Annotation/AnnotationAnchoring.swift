import CoreGraphics
import Domain
import PencilKit
import SheetMusicLayout

/// Maps freehand `PKStroke`s to/from musical anchors against a layout. Capture: each stroke -> one `DrawingAnchor`
/// whose `MusicalAnchor` is the centroid's resolved musical position and whose `encodedDrawing` is the single stroke
/// normalized to (origin = the resolved anchor point `P`, unit = the capture layout's `sp`). Display: project each
/// stored stroke to the CURRENT layout (× current `sp`, + current `P`). Reflow is therefore a pure translate + uniform
/// scale; round-trip at the same layout is exact.
enum AnnotationAnchoring {
    /// Resolved anchor point `P` (forward reference + the anchor's sp offsets) and the layout `sp`. `nil` when the
    /// forward primitive can't resolve the anchor in this layout (out-of-range measure, hidden staff).
    static func anchorPoint(for anchor: MusicalAnchor, in document: LayoutDocument) -> (point: CGPoint, sp: CGFloat)? {
        guard let ref = document.anchorReferencePoint(
            measureIndex: anchor.measureIndex,
            tickInMeasure: anchor.tickInMeasure,
            partIndex: anchor.partIndex,
            staffIndexInPart: anchor.staffIndexInPart,
        ) else { return nil }
        let point = CGPoint(
            x: ref.point.x + CGFloat(anchor.dxSp) * ref.sp,
            y: ref.point.y + CGFloat(anchor.verticalOffsetSp) * ref.sp,
        )
        return (point, ref.sp)
    }

    /// Capture transform: resolves `centroid` to a `MusicalAnchor` and returns the document→normalized affine
    /// (translate by `-P`, then scale by `1/sp`). `nil` when the centroid can't be resolved or `sp <= 0`.
    static func normalizeTransform(
        forCentroid centroid: CGPoint, in document: LayoutDocument,
    ) -> (anchor: MusicalAnchor, transform: CGAffineTransform)? {
        guard let resolved = document.resolveAnchor(at: centroid) else { return nil }
        let anchor = MusicalAnchor(
            measureIndex: resolved.measureIndex,
            tickInMeasure: resolved.tickInMeasure,
            partIndex: resolved.partIndex,
            staffIndexInPart: resolved.staffIndexInPart,
            dxSp: Double(resolved.dxSp),
            verticalOffsetSp: Double(resolved.verticalOffsetSp),
        )
        guard let (point, sp) = anchorPoint(for: anchor, in: document), sp > 0 else { return nil }
        let transform = CGAffineTransform(translationX: -point.x, y: -point.y)
            .concatenating(CGAffineTransform(scaleX: 1 / sp, y: 1 / sp))
        return (anchor, transform)
    }

    /// Display transform: normalized→document affine for `anchor` in the current layout (scale by `sp`, then translate
    /// by `P`). `nil` when the anchor can't be resolved or `sp <= 0`.
    static func displayTransform(for anchor: MusicalAnchor, in document: LayoutDocument) -> CGAffineTransform? {
        guard let (point, sp) = anchorPoint(for: anchor, in: document), sp > 0 else { return nil }
        return CGAffineTransform(scaleX: sp, y: sp)
            .concatenating(CGAffineTransform(translationX: point.x, y: point.y))
    }

    /// Re-anchor every live stroke against the current layout. Strokes whose centroid can't resolve are dropped.
    static func capture(strokes: [PKStroke], in document: LayoutDocument) -> [DrawingAnchor] {
        strokes.compactMap { stroke in
            let centroid = AnnotationAnchorPolicy.representativePoint(of: stroke)
            guard let (anchor, normalize) = normalizeTransform(forCentroid: centroid, in: document) else { return nil }
            var normalized = stroke
            normalized.transform = stroke.transform.concatenating(normalize)
            let data = PKDrawing(strokes: [normalized]).dataRepresentation()
            return DrawingAnchor(anchor: anchor, encodedDrawing: data)
        }
    }

    /// Project the stored model to the current layout as one canvas `PKDrawing`. Anchors that fail to resolve
    /// (out-of-range measure, hidden staff) are skipped (and pruned on the next save by the caller).
    static func display(_ drawings: [DrawingAnchor], in document: LayoutDocument) -> PKDrawing {
        var strokes: [PKStroke] = []
        for drawing in drawings {
            guard let denormalize = displayTransform(for: drawing.anchor, in: document) else { continue }
            guard let stored = try? PKDrawing(data: drawing.encodedDrawing),
                  let s0 = stored.strokes.first else { continue }
            var s = s0
            s.transform = s0.transform.concatenating(denormalize)
            strokes.append(s)
        }
        return PKDrawing(strokes: strokes)
    }
}
