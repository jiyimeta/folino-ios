import CoreGraphics
import Domain
import PencilKit

/// Maps freehand `PKStroke`s to/from `.page` anchors for fixed-layout PDFs. Capture: each stroke → one `DrawingAnchor`
/// whose `PageAnchor` is the page its centroid lands on and whose `encodedDrawing` is the stroke normalized to that
/// page's own frame (origin = page top-left, unit = page width). Display: re-bake each stored stroke into the page's
/// CURRENT content-space frame. Because the normalization is a fraction of page width, the same stroke renders at the
/// correct spot and size at any committed zoom — the committed-zoom factor cancels. Mirrors `AnnotationAnchoring`, with
/// page-frame geometry in place of staff-space anchoring.
enum PDFAnnotationAnchoring {
    /// The page a stroke belongs to: the frame that contains the centroid, else the page whose vertical extent is
    /// nearest (covers the inter-page gap). Vertical distance is measured to the frame's nearest edge (0 while inside
    /// the band, clamped distance to top/bottom otherwise), so a centroid at the exact midpoint of the gap ties on
    /// distance and resolves to the upper page via `firstIndex`. `nil` only when there are no pages.
    static func pageIndex(forCentroid centroid: CGPoint, pageFrames: [CGRect]) -> Int? {
        guard !pageFrames.isEmpty else { return nil }
        if let hit = pageFrames.firstIndex(where: { $0.contains(centroid) }) { return hit }
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, frame) in pageFrames.enumerated() {
            let clampedY = min(max(centroid.y, frame.minY), frame.maxY)
            let d = abs(clampedY - centroid.y)
            if d < bestDist {
                bestDist = d
                best = i
            }
        }
        return best
    }

    /// content→page-fraction: translate by `-origin`, then scale by `1/width`.
    static func normalizeTransform(pageFrame: CGRect) -> CGAffineTransform? {
        guard pageFrame.width > 0 else { return nil }
        return CGAffineTransform(translationX: -pageFrame.minX, y: -pageFrame.minY)
            .concatenating(CGAffineTransform(scaleX: 1 / pageFrame.width, y: 1 / pageFrame.width))
    }

    /// page-fraction→content: scale by `width`, then translate by `+origin`.
    static func displayTransform(pageFrame: CGRect) -> CGAffineTransform? {
        guard pageFrame.width > 0 else { return nil }
        return CGAffineTransform(scaleX: pageFrame.width, y: pageFrame.width)
            .concatenating(CGAffineTransform(translationX: pageFrame.minX, y: pageFrame.minY))
    }

    static func capture(strokes: [PKStroke], pageFrames: [CGRect]) -> [DrawingAnchor] {
        strokes.compactMap { stroke in
            let centroid = AnnotationAnchorPolicy.representativePoint(of: stroke)
            guard let index = pageIndex(forCentroid: centroid, pageFrames: pageFrames) else { return nil }
            guard let normalize = normalizeTransform(pageFrame: pageFrames[index]) else { return nil }
            // Bake the normalize into the points (same rationale as AnnotationAnchoring: PencilKit ignores a lingering
            // per-stroke transform when computing renderable extent, which clamps under zoom).
            var normalized = PKDrawing(strokes: [stroke])
            normalized.transform(using: normalize)
            return DrawingAnchor(
                kind: .page(PageAnchor(pageIndex: index)),
                encodedDrawing: normalized.dataRepresentation(),
            )
        }
    }

    static func display(_ drawings: [DrawingAnchor], pageFrames: [CGRect]) -> PKDrawing {
        var strokes: [PKStroke] = []
        for drawing in drawings {
            guard case let .page(anchor) = drawing.kind, anchor.pageIndex < pageFrames.count else { continue }
            guard let denormalize = displayTransform(pageFrame: pageFrames[anchor.pageIndex]) else { continue }
            guard var stored = try? PKDrawing(data: drawing.encodedDrawing) else { continue }
            stored.transform(using: denormalize)
            strokes.append(contentsOf: stored.strokes)
        }
        return PKDrawing(strokes: strokes)
    }

    /// Split anchors into those on `pageIndex` and the rest (off-page anchors preserved for the merge).
    static func partitionByPage(
        _ drawings: [DrawingAnchor], pageIndex: Int,
    ) -> (onPage: [DrawingAnchor], offPage: [DrawingAnchor]) {
        var onPage: [DrawingAnchor] = []
        var offPage: [DrawingAnchor] = []
        for drawing in drawings {
            if case let .page(anchor) = drawing.kind, anchor.pageIndex == pageIndex {
                onPage.append(drawing)
            } else {
                offPage.append(drawing)
            }
        }
        return (onPage, offPage)
    }

    /// Display only the anchors on `pageIndex`, denormalized into band-space `pageFrame` (the centered fitted page).
    static func displayPage(_ drawings: [DrawingAnchor], pageIndex: Int, pageFrame: CGRect) -> PKDrawing {
        guard let denormalize = displayTransform(pageFrame: pageFrame) else { return PKDrawing() }
        var strokes: [PKStroke] = []
        for drawing in drawings {
            guard case let .page(anchor) = drawing.kind, anchor.pageIndex == pageIndex else { continue }
            guard var stored = try? PKDrawing(data: drawing.encodedDrawing) else { continue }
            stored.transform(using: denormalize)
            strokes.append(contentsOf: stored.strokes)
        }
        return PKDrawing(strokes: strokes)
    }

    /// Capture band-space strokes as `.page(pageIndex)` anchors, normalized to `pageFrame`. In paged mode every stroke
    /// belongs to the single visible page, so the page is passed in rather than resolved from the centroid.
    static func capturePage(strokes: [PKStroke], pageIndex: Int, pageFrame: CGRect) -> [DrawingAnchor] {
        guard let normalize = normalizeTransform(pageFrame: pageFrame) else { return [] }
        return strokes.map { stroke in
            var normalized = PKDrawing(strokes: [stroke])
            normalized.transform(using: normalize)
            return DrawingAnchor(
                kind: .page(PageAnchor(pageIndex: pageIndex)),
                encodedDrawing: normalized.dataRepresentation(),
            )
        }
    }
}
