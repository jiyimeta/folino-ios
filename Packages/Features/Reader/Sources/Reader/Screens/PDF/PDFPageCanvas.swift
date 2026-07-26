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
            ctx.withCGContext { cg in
                PDFPageRasterizer.draw(page: page, in: cg, size: size)
            }
        }
        .aspectRatio(bounds.width / max(bounds.height, 1), contentMode: .fit)
    }
}
