import CoreGraphics
import Domain
import PencilKit
import ReaderAnnotationCore

/// iOS PencilKit adapter over the platform-neutral `PageAnchoringCore`. Bridges `PKStroke ↔ InkStroke` at the UI seam
/// and forwards the page-anchoring decisions (which page a centroid belongs to, normalize/display transforms, page
/// partitioning) to the shared core so iOS and Android bake identically. Capture: each stroke → one `DrawingAnchor`
/// whose `PageAnchor` is the page its centroid lands on and whose `encodedDrawing` is the stroke normalized to that
/// page's own frame (origin = page top-left, unit = page width). Display: re-bake each stored stroke into the page's
/// CURRENT content-space frame. Because the normalization is a fraction of page width, the same stroke renders at the
/// correct spot and size at any committed zoom — the committed-zoom factor cancels. Mirrors `AnnotationAnchoring`,
/// with page-frame geometry in place of staff-space anchoring.
enum PDFAnnotationAnchoring {
    /// The page a stroke belongs to: the frame that contains the centroid, else the page whose vertical extent is
    /// nearest (covers the inter-page gap). Delegates to the shared neutral core (single source of truth for the
    /// geometry) via the iOS layout resolver.
    static func pageIndex(forCentroid centroid: CGPoint, pageFrames: [CGRect]) -> Int? {
        PageAnchoringCore.pageIndex(forCentroid: centroid, pageFrames: pageFrames)
    }

    /// content→page-fraction: translate by `-origin`, then scale by `1/width`.
    static func normalizeTransform(pageFrame: CGRect) -> CGAffineTransform? {
        PageAnchoringCore.normalizeTransform(pageFrame: pageFrame)
    }

    /// page-fraction→content: scale by `width`, then translate by `+origin`.
    static func displayTransform(pageFrame: CGRect) -> CGAffineTransform? {
        PageAnchoringCore.displayTransform(pageFrame: pageFrame)
    }

    /// Capture: each stroke → one `DrawingAnchor` via the shared core. Pixel-erased strokes carry a `mask` the
    /// neutral `InkStroke` can't represent; they stay on the legacy `PKDrawing` archive path (read-both handles the
    /// archive permanently), same as `AnnotationAnchoring.capture`. Everything else converts to `InkStroke` and
    /// routes through `PageAnchoringCore` so iOS and Android bake identically.
    static func capture(strokes: [PKStroke], pageFrames: [CGRect]) -> [DrawingAnchor] {
        strokes.compactMap { stroke in
            if stroke.mask != nil {
                let centroid = AnnotationAnchorPolicy.representativePoint(of: stroke)
                guard let index = PageAnchoringCore.pageIndex(forCentroid: centroid, pageFrames: pageFrames),
                      let normalize = PageAnchoringCore.normalizeTransform(pageFrame: pageFrames[index])
                else { return nil }
                // Bake the normalize into the points (same rationale as AnnotationAnchoring: PencilKit ignores a
                // lingering per-stroke transform when computing renderable extent, which clamps under zoom).
                var normalized = PKDrawing(strokes: [stroke])
                normalized.transform(using: normalize)
                return DrawingAnchor(
                    kind: .page(PageAnchor(pageIndex: index)),
                    encodedDrawing: InkStrokePencilKitBridge.encodeStoredDrawing(normalized),
                )
            }
            return PageAnchoringCore.capture(
                strokes: [InkStrokePencilKitBridge.inkStroke(from: stroke)], pageFrames: pageFrames,
            ).first
        }
    }

    /// Project the stored model to the current page frames as one canvas `PKDrawing`, via the shared core's
    /// positionally-aligned display transforms.
    static func display(_ drawings: [DrawingAnchor], pageFrames: [CGRect]) -> PKDrawing {
        let transforms = PageAnchoringCore.displayTransforms(drawings, pageFrames: pageFrames)
        var strokes: [PKStroke] = []
        for (drawing, transform) in zip(drawings, transforms) {
            guard let transform else { continue }
            guard var stored = InkStrokePencilKitBridge.decodeStoredDrawing(drawing.encodedDrawing) else { continue }
            stored.transform(using: transform)
            strokes.append(contentsOf: InkStrokePencilKitBridge.bakingTransformIntoPoints(stored).strokes)
        }
        return PKDrawing(strokes: strokes)
    }

    /// Split anchors into those on `pageIndex` and the rest (off-page anchors preserved for the merge).
    static func partitionByPage(
        _ drawings: [DrawingAnchor], pageIndex: Int,
    ) -> (onPage: [DrawingAnchor], offPage: [DrawingAnchor]) {
        PageAnchoringCore.partitionByPage(drawings, pageIndex: pageIndex)
    }

    /// Display only the anchors on `pageIndex`, denormalized into band-space `pageFrame` (the centered fitted page).
    static func displayPage(_ drawings: [DrawingAnchor], pageIndex: Int, pageFrame: CGRect) -> PKDrawing {
        guard let denormalize = PageAnchoringCore.displayTransform(pageFrame: pageFrame) else { return PKDrawing() }
        var strokes: [PKStroke] = []
        for drawing in drawings {
            guard case let .page(anchor) = drawing.kind, anchor.pageIndex == pageIndex else { continue }
            guard var stored = InkStrokePencilKitBridge.decodeStoredDrawing(drawing.encodedDrawing) else { continue }
            stored.transform(using: denormalize)
            strokes.append(contentsOf: InkStrokePencilKitBridge.bakingTransformIntoPoints(stored).strokes)
        }
        return PKDrawing(strokes: strokes)
    }

    /// Capture band-space strokes as `.page(pageIndex)` anchors, normalized to `pageFrame`. In paged mode every
    /// stroke belongs to the single visible page, so the page is passed in rather than resolved from the centroid.
    /// Pixel-erased strokes take the legacy `PKDrawing` archive path, same as `capture`.
    static func capturePage(strokes: [PKStroke], pageIndex: Int, pageFrame: CGRect) -> [DrawingAnchor] {
        strokes.compactMap { stroke in
            if stroke.mask != nil {
                guard let normalize = PageAnchoringCore.normalizeTransform(pageFrame: pageFrame) else { return nil }
                var normalized = PKDrawing(strokes: [stroke])
                normalized.transform(using: normalize)
                return DrawingAnchor(
                    kind: .page(PageAnchor(pageIndex: pageIndex)),
                    encodedDrawing: InkStrokePencilKitBridge.encodeStoredDrawing(normalized),
                )
            }
            return PageAnchoringCore.capturePage(
                strokes: [InkStrokePencilKitBridge.inkStroke(from: stroke)], pageIndex: pageIndex, pageFrame: pageFrame,
            ).first
        }
    }
}
