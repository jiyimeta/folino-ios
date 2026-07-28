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
}
