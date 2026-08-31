import Domain
import Foundation

/// Where one stored drawing lands in an exported PDF. Carries a transform rather than transformed geometry: a
/// pixel-erased stroke keeps a PencilKit `mask` the neutral `InkStroke` cannot represent and is stored as a legacy
/// `PKDrawing` archive, so the renderer has to decode the drawing's own bytes and apply the transform to whatever
/// comes back. `StrokeTransform` is the same scale-plus-translate shape the Android JNI seam already consumes.
public struct InkPlacement: Equatable, Sendable {
    /// Index of the destination page in the exported document.
    public let pageIndex: Int
    /// Index into the `drawings` array that was planned.
    public let drawingIndex: Int
    /// Places the drawing's stored (normalized) geometry into that page's own space: points, origin top-left, y down.
    public let transform: StrokeTransform

    public init(pageIndex: Int, drawingIndex: Int, transform: StrokeTransform) {
        self.pageIndex = pageIndex
        self.drawingIndex = drawingIndex
        self.transform = transform
    }
}

/// One page of a paginated engraving, as the exporter will lay it out.
public struct EngravedPagePlacement: Equatable, Sendable {
    /// Document-space Y at which this page's content begins.
    public let startY: CGFloat
    /// The page's usable height — page height minus that page's top and bottom margins. The page owns document Y in
    /// `[startY, startY + usableHeight)`.
    public let usableHeight: CGFloat
    /// Document → page X translation (the page's leading margin).
    public let offsetX: CGFloat
    /// Document → page Y translation (the page's top margin minus `startY`).
    public let offsetY: CGFloat

    public init(startY: CGFloat, usableHeight: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
        self.startY = startY
        self.usableHeight = usableHeight
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

/// Platform-neutral placement for annotated PDF export: which stored drawing lands on which exported page, and the
/// transform that puts it there. Foundation + Domain only — no PencilKit, no CoreGraphics, no layout engine — so it
/// cross-compiles for Android and is the single source of truth both platforms call. iOS decodes each drawing to a
/// `PKDrawing` and applies the transform; Android feeds the same transform to androidx.ink.
///
/// Sibling of `AnnotationAnchoringCore` (which places ink into a *screen* layout) — the only difference is that the
/// destination is a page of a fixed-size document rather than a scrolling viewport.
public enum AnnotatedExportPlanner {
    /// Engraved base. Resolves each `.musical` anchor against `resolver` (the export layout, NOT the reader's), keeps
    /// it on the page whose band contains the resolved point, and folds that page's offsets into the translation.
    ///
    /// Anchors that fail to resolve — a measure the export layout does not have — are dropped rather than placed at a
    /// guessed position, matching what the Reader does with the same anchor. `.page` anchors are ignored: they belong
    /// to the original PDF, which is a different export.
    public static func planEngraved(
        drawings: [DrawingAnchor],
        resolver: AnchorResolving,
        pages: [EngravedPagePlacement],
    ) -> [InkPlacement] {
        var placements: [InkPlacement] = []
        for (index, drawing) in drawings.enumerated() {
            guard case let .musical(anchor) = drawing.kind,
                  let (point, sp) = AnnotationAnchoringCore.anchorPoint(for: anchor, using: resolver), sp > 0,
                  let pageIndex = pageIndex(forY: point.y, in: pages)
            else { continue }
            let page = pages[pageIndex]
            placements.append(InkPlacement(
                pageIndex: pageIndex,
                drawingIndex: index,
                transform: StrokeTransform(sp: sp, px: point.x + page.offsetX, py: point.y + page.offsetY),
            ))
        }
        return placements
    }

    /// The page whose band contains `y`, with page 1's band extended downward without bound. A mark drawn above the
    /// top staff of page 1 (headroom for a circled note, an arrow, a fermata) can resolve to a point above document
    /// Y = 0 — `verticalOffsetSp` is negative and page 1's band has nothing above `startY == 0` to catch it — but
    /// that point is still unambiguously page 1's ink, not nowhere, so page 1's lower bound is widened rather than
    /// left to drop the placement.
    ///
    /// Every other page keeps its strict `[startY, startY + usableHeight)` bounds, INCLUDING the last page's upper
    /// bound: a point past the last page's band is a sign the anchor resolved somewhere the export layout does not
    /// actually reach (`an anchor beyond the last page's band is dropped`, below) and dropping it rather than
    /// guessing "the last page" is the same caution `planEngraved`'s doc comment already applies to an anchor the
    /// layout can't resolve at all. The only points an interior page's clamp can still miss are the pathological
    /// spillover gap `EngravedExportLayout` already documents (a single system taller than a page's usable height),
    /// which is unrelated to this edge case.
    private static func pageIndex(forY y: CGFloat, in pages: [EngravedPagePlacement]) -> Int? {
        if let first = pages.first, y < first.startY {
            return 0
        }
        return pages.firstIndex(where: { y >= $0.startY && y < $0.startY + $0.usableHeight })
    }

    /// Original-PDF base. `pageFrames` are the destination pages' boxes in points, in page order; pass each page's
    /// own frame with a zero origin, since the geometry produced here is page-local.
    ///
    /// Page anchors normalize to a fraction of page width, so the transform is exact at any page size and no
    /// reflow happens — the pages are the same fixed-layout pages the ink was drawn on.
    public static func planPaged(
        drawings: [DrawingAnchor],
        pageFrames: [CGRect],
    ) -> [InkPlacement] {
        let transforms = PageAnchoringCore.displayStrokeTransforms(drawings, pageFrames: pageFrames)
        var placements: [InkPlacement] = []
        for (index, drawing) in drawings.enumerated() {
            guard case let .page(anchor) = drawing.kind,
                  index < transforms.count, let transform = transforms[index]
            else { continue }
            placements.append(InkPlacement(
                pageIndex: anchor.pageIndex, drawingIndex: index, transform: transform,
            ))
        }
        return placements
    }
}
