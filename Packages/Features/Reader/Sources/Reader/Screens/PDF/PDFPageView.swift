import PDFKit
import SwiftUI

/// One PDF page, fitted into `viewport` and SHARP at committed `zoom`. Rendered at `fitted × zoom` resolution then
/// pre-scaled `1/zoom` into a `fitted`-sized slot, so the host surface's `scaleEffect(zoom)` cancels the pre-scale and
/// the page is sharp at zoom (a plain `scaleEffect` on a PDF `Canvas` would blur — withCGContext does not re-rasterize
/// under scaleEffect). `zoom` MUST be the same value the surface scales the band by (`viewModel.viewportZoom`).
struct PDFPageView: View {
    let page: PDFPage
    let viewport: CGSize
    let zoom: CGFloat

    var body: some View {
        let bounds = page.bounds(for: .mediaBox)
        let fit = fitScale(page: bounds.size, viewport: viewport)
        let w = bounds.width * fit
        let h = bounds.height * fit
        let z = max(zoom, 0.01)
        return PDFPageCanvas(page: page)
            .frame(width: w * z, height: h * z)
            .scaleEffect(1 / z, anchor: .topLeading)
            .frame(width: w, height: h, alignment: .topLeading)
            .frame(width: viewport.width, height: viewport.height) // center the fitted page in the page band
    }

    private func fitScale(page: CGSize, viewport: CGSize) -> CGFloat {
        guard page.width > 0, page.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(viewport.width / page.width, viewport.height / page.height)
    }
}
