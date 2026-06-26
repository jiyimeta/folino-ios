import PDFKit
import SwiftUI

/// Draws one PDF page's VECTOR content into a SwiftUI `Canvas`. Because `Canvas` re-runs its draw closure at the
/// rendered (post-`scaleEffect`) resolution, the page stays sharp at any zoom — the same mechanism that keeps the
/// score's `ScoreView` Canvas sharp under zoom. No pre-rasterization / cache needed.
struct PDFPageCanvas: View {
    let page: PDFPage

    var body: some View {
        let bounds = page.bounds(for: .mediaBox)
        Canvas(rendersAsynchronously: false) { ctx, size in
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            ctx.withCGContext { cg in
                cg.saveGState()
                // Center within `size`, flip into PDF's bottom-left origin, scale points → view space.
                let drawnW = bounds.width * scale, drawnH = bounds.height * scale
                cg.translateBy(x: (size.width - drawnW) / 2, y: (size.height - drawnH) / 2)
                cg.translateBy(x: 0, y: drawnH)
                cg.scaleBy(x: scale, y: -scale)
                cg.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
                cg.setFillColor(UIColor.white.cgColor)
                cg.fill(bounds)
                page.draw(with: .mediaBox, to: cg)
                cg.restoreGState()
            }
        }
        .aspectRatio(bounds.width / max(bounds.height, 1), contentMode: .fit)
    }
}
