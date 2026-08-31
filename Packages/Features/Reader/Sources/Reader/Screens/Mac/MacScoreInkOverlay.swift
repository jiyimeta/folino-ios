#if os(macOS)
import PencilKit
import SwiftUI

/// Committed annotation ink, flattened over a Mac score surface.
///
/// **Display only, and that is the point.** Ink authored on an iPad is part of the score as far as the user is
/// concerned; a Mac that renders the notation and silently drops the ink looks exactly like a Mac that lost the data.
/// Annotation *input* is a later sub-project's (there is no `PKCanvasView` on macOS at all — PencilKit ships the model
/// types and the raster, not the canvas), so this layer is the whole of the Mac's annotation story for now.
///
/// **Why it bands rather than rasterizing the surface in one go.** `StaticInkLayer` renders `size` in full, which is
/// what the iOS paged reader wants because its band is one screen. The Mac's vertical surface is the whole engraved
/// document — 14,000 pt tall for a three-minute piece — and a single raster of that at backing scale is over a hundred
/// megabytes. Slicing bounds the cost by `sliceHeight` and, because a slice with no stroke in it is skipped outright,
/// sparse ink (the normal case: a handful of marks on one system) costs one small raster no matter how long the score
/// is.
///
/// Everything is in the surrounding surface's own coordinate space, which for both Mac containers is the
/// `LayoutDocument`'s: `drawing` is already projected there by `AnnotationAnchoring.display`, and `band` names the part
/// of it the caller can actually show. Strokes are selected by geometry (`renderBounds`), not by their anchor's
/// resolved point, so a stroke that straddles a page boundary is drawn on both sheets and clipped by each — which is
/// what a mark drawn across the fold should look like.
struct MacScoreInkOverlay: View {
    /// Ink already projected into the surface's coordinate space.
    let drawing: PKDrawing
    /// The surface this overlay covers, so it lines up with the sibling `ScoreView` in a top-leading `ZStack`.
    let surfaceSize: CGSize
    /// The part of `surfaceSize` worth rasterizing, in the same space. Ink outside it is skipped.
    let band: CGRect

    /// Tallest slice rasterized in one `PKDrawing.image(from:scale:)` call. At a typical engraved width (~530 pt) and
    /// a 2x backing scale one slice is about 8 MB — the size of a screenful, which is the right unit for a surface
    /// that is scrolled.
    private static let sliceHeight: CGFloat = 1024

    var body: some View {
        ZStack(alignment: .topLeading) {
            // A zero-cost floor so the overlay keeps the surface's size even when there is no ink at all.
            Color.clear
            ForEach(slices, id: \.rect) { slice in
                StaticInkLayer(drawing: slice.drawing, size: slice.rect.size)
                    .offset(x: slice.rect.minX, y: slice.rect.minY)
            }
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// The rasters to draw: the inked part of `band`, cut into `sliceHeight` strips, each carrying only the strokes it
    /// actually intersects and translated so that strip's top-left is the drawing's origin (what `StaticInkLayer`
    /// renders from). Strips with no strokes are dropped, which is what makes sparse ink cheap.
    private var slices: [Slice] {
        guard !drawing.strokes.isEmpty else { return [] }
        let inked = drawing.bounds.intersection(band)
        guard !inked.isNull, inked.width > 0, inked.height > 0 else { return [] }
        var result: [Slice] = []
        var top = inked.minY
        while top < inked.maxY {
            let height = min(Self.sliceHeight, inked.maxY - top)
            let rect = CGRect(x: inked.minX, y: top, width: inked.width, height: height)
            top += height
            let strokes = drawing.strokes.filter { $0.renderBounds.intersects(rect) }
            guard !strokes.isEmpty else { continue }
            var sliced = PKDrawing(strokes: strokes)
            sliced.transform(using: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            result.append(Slice(rect: rect, drawing: sliced))
        }
        return result
    }

    private struct Slice {
        let rect: CGRect
        let drawing: PKDrawing
    }
}
#endif
