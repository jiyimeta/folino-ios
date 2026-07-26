import CoreGraphics
import PDFKit

/// Draws one PDF page's vector content into a `CGContext`, fitted and centered in `size`.
///
/// Deliberately bypasses `PDFPage.draw(with:to:)` and replays the page through CoreGraphics
/// (`CGContext.drawPDFPage`) instead. `PDFPage.draw` derives the device resolution from the context's `ctm` and
/// applies a legibility floor to thin strokes — roughly 0.75pt when it believes it is drawing at 1×. Inside a SwiftUI
/// `Canvas`, `withCGContext` hands over a context whose `ctm` is the IDENTITY (the display scale lives in the
/// context's base transform, visible only through `userSpaceToDeviceSpaceTransform`), so `PDFPage.draw` always
/// concludes it is rendering at 1× and inflates every hairline. Measured against engraved sheet music, whose staff
/// lines are ~0.25pt, that is a uniform 3× overdraw: staff lines, stems, and ledger lines all render at triple width
/// and saturate to solid black, which reads as a muddy, low-quality page next to Files.app / `PDFView`.
/// `CGContext.drawPDFPage` has no such floor and reproduces `PDFPage.draw` exactly (pixel-identical) once the floor
/// stops applying, so the page keeps its true stroke weights at every zoom.
enum PDFPageRasterizer {
    /// Fills `size` white and draws `page` into it, scaled to fit and centered. The context is expected to be in
    /// UIKit orientation (top-left origin, y down) — the page's own bottom-left space is set up here.
    static func draw(page: PDFPage, in cg: CGContext, size: CGSize) {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0, let cgPage = page.pageRef else { return }
        let scale = min(size.width / bounds.width, size.height / bounds.height)

        cg.saveGState()
        // Center within `size`, flip into PDF's bottom-left origin, scale points → view space.
        let drawnW = bounds.width * scale, drawnH = bounds.height * scale
        cg.translateBy(x: (size.width - drawnW) / 2, y: (size.height - drawnH) / 2)
        cg.translateBy(x: 0, y: drawnH)
        cg.scaleBy(x: scale, y: -scale)
        cg.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        cg.setFillColor(gray: 1, alpha: 1)
        cg.fill(bounds)

        // `getDrawingTransform` applies the page's `/Rotate` and fits the rotated page into `bounds`; for the common
        // unrotated page it reduces to the identity.
        cg.saveGState()
        cg.concatenate(cgPage.getDrawingTransform(.mediaBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
        cg.drawPDFPage(cgPage)
        cg.restoreGState()

        // `drawPDFPage` replays only the content stream, so any annotations baked into the imported PDF (highlights
        // or ink from another app, form field appearances) still need PDFKit — `PDFPage.draw` used to cover these.
        // folino's own Apple Pencil ink is a separate PencilKit layer and never lands here.
        for annotation in page.annotations where annotation.shouldDisplay {
            annotation.draw(with: .mediaBox, in: cg)
        }
        cg.restoreGState()
    }
}
