import Domain
import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Platform-neutral projection of the PDF playback cursor, the read-only sibling of `PageAnchoringCore`. The OMR
/// side-car reports the cursor as a rectangle in ONE PDF page's own point space (top-left origin, y-down — see
/// swift-sheet-music's `PdfRectWire`); every reader surface then has to place that rectangle over the page as it is
/// currently drawn. That placement is the same arithmetic on both platforms, so it lives here once and both call it:
/// iOS directly (`VerticalPDFContainer` / `PagedPDFContainer`), Android over JNI (`nativePdfCursorDisplayRect`).
///
/// The one thing that is NOT shared is what a "page frame" means to a given surface — iOS's continuous reader lays
/// pages out in unzoomed PDF-point space, iOS page mode fits one page to a band, and both Android surfaces work in
/// raster pixels. That is layout, not logic: each surface passes its own page frame in and gets a rect back in the
/// same space it asked in.
///
/// The same placement read backwards is tap-to-seek (`pagePoint` / `pageHit`): a tap arrives in the surface's content
/// space and has to become "page N, at this point in page N's own points" before a PDF hit-test can say what was
/// tapped. It is the same one factor and the same one origin, so it lives here beside the forward direction rather
/// than being re-derived per platform.
public enum PDFCursorProjection {
    /// How far a renderer's own idea of a page's width may differ from the OMR side-car's before the two are treating
    /// the document as different sizes. The two are both PDF points read from the same file, so they should agree
    /// exactly; a real difference means the cursor is about to be placed against geometry it was not measured in.
    public static let pageWidthTolerancePt: CGFloat = 0.5

    /// Whether the rendering side's page width agrees with the side-car's, within [pageWidthTolerancePt]. A caller
    /// that gets `false` should report it (a non-fatal, once per document) and still draw — a cursor placed slightly
    /// wrong is more useful than a cursor silently missing, and the mis-scale is exactly the kind of drift that
    /// otherwise goes unnoticed. An unknown side-car width (`<= 0`) counts as agreement: there is nothing to
    /// disagree with, and `displayRect` already declines to place against it.
    public static func pageWidthsAgree(
        renderedPageWidthPt: CGFloat,
        geometryPageWidthPt: CGFloat,
        tolerancePt: CGFloat = pageWidthTolerancePt,
    ) -> Bool {
        guard geometryPageWidthPt > 0 else { return true }
        return abs(renderedPageWidthPt - geometryPageWidthPt) <= tolerancePt
    }

    /// Place a side-car cursor rect (in `geometryPageWidthPt`-wide page-point space, top-left origin) into the frame
    /// its page currently occupies in a surface's own content space.
    ///
    /// The scale is `pageFrame.width / geometryPageWidthPt` — one factor for both axes, since a PDF page is rendered
    /// at a uniform scale — and the page's origin is then added, so the result is in exactly the space `pageFrame`
    /// was expressed in (unzoomed points on iOS's continuous reader, band points in iOS page mode, raster pixels on
    /// both Android surfaces).
    ///
    /// `nil` when the placement is undefined rather than merely degenerate: a side-car that never recorded this
    /// page's size (`geometryPageWidthPt <= 0` — see `PdfPageSizesWire`'s own "unknown" encoding) or a page not
    /// currently laid out (`pageFrame.width <= 0`). Callers draw nothing in that case, which is what iOS's PDF
    /// readers already did before this projection was lifted here.
    public static func displayRect(
        cursorRect: CGRect,
        geometryPageWidthPt: CGFloat,
        pageFrame: CGRect,
    ) -> CGRect? {
        guard geometryPageWidthPt > 0, pageFrame.width > 0 else { return nil }
        let scale = pageFrame.width / geometryPageWidthPt
        return CGRect(
            x: pageFrame.minX + cursorRect.minX * scale,
            y: pageFrame.minY + cursorRect.minY * scale,
            width: cursorRect.width * scale,
            height: cursorRect.height * scale,
        )
    }

    /// A tap resolved onto the displayed document: which page it landed on, and where on that page in the page's OWN
    /// point space (top-left origin, y-down — exactly the space swift-sheet-music's `PDFScoreGeometry` hit-test takes,
    /// and the space `displayRect`'s `cursorRect` comes out of).
    public struct PageHit: Equatable, Sendable {
        public let pageIndex: Int
        public let point: CGPoint

        public init(pageIndex: Int, point: CGPoint) {
            self.pageIndex = pageIndex
            self.point = point
        }
    }

    /// The exact inverse of `displayRect`'s placement, for one page: a point in the surface's own content space →
    /// that page's own point space. Same single uniform scale, applied the other way round — subtract the page's
    /// origin, then divide.
    ///
    /// Does NOT test containment; that is `pageHit`'s job, because "which page is under this point" is a decision
    /// about a whole layout, not about one frame. `nil` under the same conditions `displayRect` declines: an unknown
    /// side-car page width, or a page with no current frame.
    public static func pagePoint(
        contentPoint: CGPoint,
        geometryPageWidthPt: CGFloat,
        pageFrame: CGRect,
    ) -> CGPoint? {
        guard geometryPageWidthPt > 0, pageFrame.width > 0 else { return nil }
        let scale = pageFrame.width / geometryPageWidthPt
        return CGPoint(
            x: (contentPoint.x - pageFrame.minX) / scale,
            y: (contentPoint.y - pageFrame.minY) / scale,
        )
    }

    /// Resolve a tap in a surface's own content space to the page under it plus that page's own point-space
    /// location — the input a PDF hit-test wants. `pageFrames` and `geometryPageWidthsPt` are both positionally
    /// indexed by page, the same two arrays the cursor path already threads through `displayRect`.
    ///
    /// Containment is STRICT: the first frame that actually contains the point wins, and a point that lands on no
    /// page is `nil`. There is deliberately no nearest-page fallback here, unlike
    /// `PageAnchoringCore.pageIndex(forCentroid:pageFrames:)` — a stroke that straddles the inter-page gutter still
    /// has to be filed somewhere, but a tap in the gutter (or in a paged surface's letterbox margin) is a tap on
    /// nothing, and "nothing happens" is the behavior both platforms want there.
    ///
    /// Pages the caller isn't currently showing need no special-casing at the call site: a page with no frame this
    /// layout (paged mode's zero-width placeholder for every off-screen page) contains nothing, and a page whose
    /// width the side-car never recorded can't be scaled into, so both are skipped exactly as `displayRect` declines
    /// them. A `geometryPageWidthsPt` shorter than `pageFrames` reads as "unknown" past its end, for the same reason.
    public static func pageHit(
        contentPoint: CGPoint,
        geometryPageWidthsPt: [CGFloat],
        pageFrames: [CGRect],
    ) -> PageHit? {
        for (index, frame) in pageFrames.enumerated() where frame.contains(contentPoint) {
            let widthPt = index < geometryPageWidthsPt.count ? geometryPageWidthsPt[index] : 0
            guard let point = pagePoint(
                contentPoint: contentPoint, geometryPageWidthPt: widthPt, pageFrame: frame,
            ) else { continue }
            return PageHit(pageIndex: index, point: point)
        }
        return nil
    }
}
