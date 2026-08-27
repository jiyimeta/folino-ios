import CoreGraphics
import Domain
import PencilKit
import ReaderAnnotationCore
import SheetMusicLayout

/// iOS PencilKit adapter over the platform-neutral `AnnotationAnchoringCore`. Bridges `PKStroke ↔ InkStroke` at the UI
/// seam and forwards the anchoring decisions (resolve, compose `P`, normalize, project) to the shared core so iOS and
/// Android bake identically. Capture: each stroke -> one `DrawingAnchor` whose `MusicalAnchor` is the centroid's
/// resolved musical position and whose `encodedDrawing` is the single stroke normalized to (origin = the resolved
/// anchor point `P`, unit = the capture layout's `sp`). Display: project each stored stroke to the CURRENT layout
/// (× current `sp`, + current `P`). Reflow is therefore a pure translate + uniform scale; round-trip at the same
/// layout is exact. The paged band-space variants (`capturePaged` / `displayPaged`) keep their PencilKit mechanics for
/// now; only the non-paged score path and `partitionByPage` route through the core.
///
/// **Every entry point takes a `staffFilter`.** Stored anchors are in SOURCE addressing, while the `LayoutDocument`
/// the reader renders is engraved from `filtered(hidingStaves:)` and therefore renumbers its staves. The filter is the
/// translation between the two, applied by wrapping the resolver (`FilteredStaffAnchorResolver`) so it lands on
/// resolve and reference-point lookup alike — the display side AND the capture side. `nil` means nothing is hidden and
/// the two addressings coincide.
enum AnnotationAnchoring {
    /// The layout resolver these functions run against: the plain document resolver, wrapped so it speaks source
    /// addressing whenever a staff is hidden.
    private static func resolver(
        for document: LayoutDocument, staffFilter: AnnotationStaffFilter?,
    ) -> AnchorResolving {
        let base = LayoutDocumentAnchorResolver(document: document)
        guard let staffFilter else { return base }
        return FilteredStaffAnchorResolver(base: base, filter: staffFilter)
    }

    /// Resolved anchor point `P` (forward reference + the anchor's sp offsets) and the layout `sp`. `nil` when the
    /// forward primitive can't resolve the anchor in this layout (out-of-range measure, hidden staff). Delegates to the
    /// shared neutral core (single source of truth for the composition formula) via the iOS layout resolver.
    static func anchorPoint(
        for anchor: MusicalAnchor, in document: LayoutDocument, staffFilter: AnnotationStaffFilter? = nil,
    ) -> (point: CGPoint, sp: CGFloat)? {
        AnnotationAnchoringCore.anchorPoint(
            for: anchor, using: resolver(for: document, staffFilter: staffFilter),
        )
    }

    /// Capture transform: resolves `centroid` to a `MusicalAnchor` and returns the document→normalized affine
    /// (translate by `-P`, then scale by `1/sp`). `nil` when the centroid can't be resolved or `sp <= 0`.
    ///
    /// Resolution goes through the (possibly wrapped) resolver rather than `document.resolveAnchor` directly, so the
    /// anchor it returns is in source addressing. Reading the document straight would stamp the FILTERED staff number
    /// into a stored anchor — see `AnnotationStaffFilter`.
    static func normalizeTransform(
        forCentroid centroid: CGPoint, in document: LayoutDocument, staffFilter: AnnotationStaffFilter? = nil,
    ) -> (anchor: MusicalAnchor, transform: CGAffineTransform)? {
        let resolver = resolver(for: document, staffFilter: staffFilter)
        guard let anchor = resolver.resolveAnchor(at: centroid),
              let (point, sp) = AnnotationAnchoringCore.anchorPoint(for: anchor, using: resolver), sp > 0
        else { return nil }
        let transform = CGAffineTransform(translationX: -point.x, y: -point.y)
            .concatenating(CGAffineTransform(scaleX: 1 / sp, y: 1 / sp))
        return (anchor, transform)
    }

    /// Display transform: normalized→document affine for `anchor` in the current layout (scale by `sp`, then translate
    /// by `P`). `nil` when the anchor can't be resolved or `sp <= 0`.
    static func displayTransform(
        for anchor: MusicalAnchor, in document: LayoutDocument, staffFilter: AnnotationStaffFilter? = nil,
    ) -> CGAffineTransform? {
        guard let (point, sp) = anchorPoint(for: anchor, in: document, staffFilter: staffFilter), sp > 0 else {
            return nil
        }
        return CGAffineTransform(scaleX: sp, y: sp)
            .concatenating(CGAffineTransform(translationX: point.x, y: point.y))
    }

    /// Re-anchor every live stroke against the current layout via the shared neutral core. Strokes whose centroid can't
    /// resolve are dropped. Pixel-erased strokes carry a `mask` the neutral `InkStroke` can't represent; they stay on
    /// the legacy `PKDrawing` archive path (read-both handles the archive permanently). Everything else routes through
    /// `AnnotationAnchoringCore` so iOS and Android bake identically.
    ///
    /// The anchors that come back are always in SOURCE addressing, whatever is hidden — that is what makes a capture
    /// taken with a staff hidden survive un-hiding it.
    static func capture(
        strokes: [PKStroke], in document: LayoutDocument, staffFilter: AnnotationStaffFilter? = nil,
    ) -> [DrawingAnchor] {
        let resolver = resolver(for: document, staffFilter: staffFilter)
        return strokes.compactMap { stroke in
            if stroke.mask != nil {
                let centroid = AnnotationAnchorPolicy.representativePoint(of: stroke)
                guard let (anchor, normalize) = normalizeTransform(
                    forCentroid: centroid, in: document, staffFilter: staffFilter,
                ) else {
                    return nil
                }
                var normalized = PKDrawing(strokes: [stroke])
                normalized.transform(using: normalize)
                return DrawingAnchor(
                    kind: .musical(anchor),
                    encodedDrawing: InkStrokePencilKitBridge.encodeStoredDrawing(normalized),
                )
            }
            return AnnotationAnchoringCore.capture(
                strokes: [InkStrokePencilKitBridge.inkStroke(from: stroke)], using: resolver,
            ).first
        }
    }

    /// Split anchors into those whose resolved point falls in the page band `[pageStartY, pageEndY)` and the rest.
    /// Anchors that fail to resolve in this layout go to `offPage` (preserved, never dropped) so a page-scoped
    /// re-capture can't delete ink it cannot currently place. A hidden staff's ink lands there too, which is exactly
    /// right: it is off screen, so this page's canvas cannot describe it.
    static func partitionByPage(
        _ drawings: [DrawingAnchor], in document: LayoutDocument, pageStartY: CGFloat, pageEndY: CGFloat,
        staffFilter: AnnotationStaffFilter? = nil,
    ) -> (onPage: [DrawingAnchor], offPage: [DrawingAnchor]) {
        AnnotationAnchoringCore.partitionByPage(
            drawings, using: resolver(for: document, staffFilter: staffFilter),
            pageStartY: pageStartY, pageEndY: pageEndY,
        )
    }

    /// Project the anchors resolving onto `[pageStartY, pageEndY)` into page-local "band" space (band origin = page
    /// top-left): document→band is translate(+contentPadding, -pageStartY), composed onto the per-anchor denormalize.
    static func displayPaged(
        _ drawings: [DrawingAnchor], in document: LayoutDocument,
        pageStartY: CGFloat, pageEndY: CGFloat, contentPadding: CGFloat,
        staffFilter: AnnotationStaffFilter? = nil,
    ) -> PKDrawing {
        let docToBand = CGAffineTransform(translationX: contentPadding, y: -pageStartY)
        var strokes: [PKStroke] = []
        for drawing in drawings {
            guard case let .musical(anchor) = drawing.kind,
                  let (point, _) = anchorPoint(for: anchor, in: document, staffFilter: staffFilter),
                  point.y >= pageStartY, point.y < pageEndY,
                  let denormalize = displayTransform(for: anchor, in: document, staffFilter: staffFilter),
                  var stored = InkStrokePencilKitBridge.decodeStoredDrawing(drawing.encodedDrawing)
            else { continue }
            stored.transform(using: denormalize.concatenating(docToBand))
            strokes.append(contentsOf: InkStrokePencilKitBridge.bakingTransformIntoPoints(stored).strokes)
        }
        return PKDrawing(strokes: strokes)
    }

    /// Capture band-space strokes (band→document is translate(-contentPadding, +pageStartY)) into musical anchors.
    /// Same normalization as `capture`, after lifting each stroke back into full-document coordinates so the centroid
    /// resolves against the layout.
    static func capturePaged(
        strokes: [PKStroke], in document: LayoutDocument, pageStartY: CGFloat, contentPadding: CGFloat,
        staffFilter: AnnotationStaffFilter? = nil,
    ) -> [DrawingAnchor] {
        let bandToDoc = CGAffineTransform(translationX: -contentPadding, y: pageStartY)
        return strokes.compactMap { stroke in
            var docDrawing = PKDrawing(strokes: [stroke])
            docDrawing.transform(using: bandToDoc)
            guard let docStroke = docDrawing.strokes.first else { return nil }
            let centroid = AnnotationAnchorPolicy.representativePoint(of: docStroke)
            guard let (anchor, normalize) = normalizeTransform(
                forCentroid: centroid, in: document, staffFilter: staffFilter,
            ) else { return nil }
            var normalized = PKDrawing(strokes: [docStroke])
            normalized.transform(using: normalize)
            return DrawingAnchor(
                kind: .musical(anchor),
                encodedDrawing: InkStrokePencilKitBridge.encodeStoredDrawing(normalized),
            )
        }
    }

    /// Project the stored model to the current layout as one canvas `PKDrawing` via the shared neutral core. Anchors
    /// that fail to resolve (out-of-range measure, hidden staff) are skipped (and pruned on the next save by the
    /// caller). Neutral `InkStroke` blobs are placed by the core's transform — the placed geometry is full-size at its
    /// document position, so PencilKit renders it without the transform-clamp workaround. Legacy `PKDrawing` archives
    /// (pixel-erased strokes) take the affine-and-bake path as before. Read-both is preserved permanently.
    static func display(
        _ drawings: [DrawingAnchor], in document: LayoutDocument, staffFilter: AnnotationStaffFilter? = nil,
    ) -> PKDrawing {
        let transforms = AnnotationAnchoringCore.display(
            drawings, using: resolver(for: document, staffFilter: staffFilter),
        )
        var strokes: [PKStroke] = []
        for (drawing, transform) in zip(drawings, transforms) {
            guard let transform else { continue }
            let data = drawing.encodedDrawing
            if InkStrokeCodec.isInkStroke(data) {
                guard let stored = try? InkStrokeCodec.decode(data) else { continue }
                let placed = AnnotationAnchoringCore.place(stored, with: transform)
                strokes.append(InkStrokePencilKitBridge.pkStroke(from: placed))
            } else {
                // Legacy PKDrawing archive: apply the same affine the core's transform encodes and bake into points.
                // PencilKit derives its content extent from PATH BOUNDS and ignores the per-stroke transform, so a
                // normalized path carrying a large scale `.transform` renders outside the extent and clamps under zoom;
                // baking makes the ink full-size at its document position so the canvas renders it without clamping.
                guard var stored = try? PKDrawing(data: data) else { continue }
                let affine = CGAffineTransform(scaleX: transform.sp, y: transform.sp)
                    .concatenating(CGAffineTransform(translationX: transform.px, y: transform.py))
                stored.transform(using: affine)
                strokes.append(contentsOf: InkStrokePencilKitBridge.bakingTransformIntoPoints(stored).strokes)
            }
        }
        return PKDrawing(strokes: strokes)
    }
}
