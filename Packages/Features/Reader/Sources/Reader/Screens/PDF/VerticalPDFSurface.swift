// PARITY(macos): the hosted PDF page stack for `VerticalPDFContainer` — see the marker on that file for what Ⅳ's
//   Mac reading surface needs. Also reaches `Color(.secondarySystemBackground)`, an iOS-only dynamic color.

#if os(iOS)
import Domain
import PDFKit
import ReaderAnnotationCore
import SheetMusicCore
import SwiftUI

/// The hosted PDF page stack. A separate `View` (like `VerticalZoomedSurface`) so it reads `pinch.*` /
/// `viewModel.viewportZoom` directly and SwiftUI observation delivers animated commit updates inside the
/// `ScoreScrollHost`, rather than through `rootView` reassignment (which drops the animation transaction). Pages are
/// laid out at their natural sizes; the committed zoom × fit-to-width scale is applied here via `scaleEffect`, matching
/// `VerticalZoomedSurface` so the annotation overlay's pivot geometry is identical.
struct VerticalPDFSurface: View {
    @Bindable var viewModel: ReaderViewModel
    @Bindable var pinch: PinchState
    let document: PDFDocument
    let viewport: CGSize
    let pageGap: CGFloat
    let pageSizes: [CGSize]
    /// Blank content-space height above the first page, so it clears the Reader's self-drawn top bar the scroll
    /// slides under. Every content-space y in this view starts from it.
    let topInset: CGFloat

    var body: some View {
        let cw = pageSizes.map(\.width).max() ?? 0
        let stackHeight = pageSizes.reduce(0) { $0 + $1.height }
            + pageGap * CGFloat(max(0, pageSizes.count - 1)) + topInset
        let zoom = cw > 0 ? viewModel.viewportZoom * (viewport.width / cw) : viewModel.viewportZoom
        return pageStack(contentWidth: cw, zoom: zoom)
            // Cursor lives in the same unzoomed content space as the pages, so it rides both scaleEffects + offset.
                .overlay(alignment: .topLeading) { cursorOverlay(contentWidth: cw) }
                // Tap-to-seek in content space (the named space is declared here, before the scaleEffects).
                .coordinateSpace(name: Self.seekSpace)
                .gesture(seekGesture(contentWidth: cw))
                .scaleEffect(pinch.magnification, anchor: pinch.anchor)
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(x: pinch.offsetX, y: 0)
                .frame(width: cw * zoom, height: stackHeight * zoom, alignment: .topLeading)
    }

    /// Named coordinate space for tap-to-seek — the unzoomed content space of the stacked pages.
    static let seekSpace = "pdfVerticalSeek"

    private func seekGesture(contentWidth: CGFloat) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named(Self.seekSpace)).onEnded { value in
            guard !viewModel.isAnnotating,
                  let geometry = viewModel.pdfPlaybackData?.geometry,
                  let (page, point) = pageAndPoint(atContent: value.location, contentWidth: contentWidth),
                  let cursor = geometry.cursor(at: point, pageIndex: page) else { return }
            viewModel.playbackSession.setManualCursor(cursor)
        }
    }

    /// Resolve a content-space point to (page index, in-page top-left mediaBox point), or `nil` if it's in a gap.
    private func pageAndPoint(atContent point: CGPoint, contentWidth: CGFloat) -> (page: Int, point: CGPoint)? {
        var y: CGFloat = topInset
        for (index, size) in pageSizes.enumerated() {
            let pageX = (contentWidth - size.width) / 2
            if CGRect(x: pageX, y: y, width: size.width, height: size.height).contains(point) {
                return (index, CGPoint(x: point.x - pageX, y: point.y - y))
            }
            y += size.height + pageGap
        }
        return nil
    }

    @ViewBuilder
    private func cursorOverlay(contentWidth: CGFloat) -> some View {
        if let cursor = viewModel.pdfDisplayCursorRect,
           let rect = contentRect(for: cursor, contentWidth: contentWidth)
        {
            Rectangle()
                .fill(PDFPlaybackCursor.color)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    /// The cursor's rect in this surface's unzoomed content space, matching `pageStack`'s centered VStack layout.
    /// The stacked page frame is this surface's own layout; placing the cursor INTO that frame is the shared
    /// `PDFCursorProjection` both platforms call (Android reaches it over JNI).
    private func contentRect(for cursor: PDFCursorRect, contentWidth: CGFloat) -> CGRect? {
        guard pageSizes.indices.contains(cursor.pageIndex),
              let pageWidthPt = viewModel.pdfPlaybackData?.geometry.pageSizes[cursor.pageIndex]?.width
        else { return nil }
        var y: CGFloat = topInset
        for (index, size) in pageSizes.enumerated() {
            if index == cursor.pageIndex {
                let frame = CGRect(
                    x: (contentWidth - size.width) / 2, y: y, width: size.width, height: size.height,
                )
                return PDFCursorProjection.displayRect(
                    cursorRect: cursor.rect, geometryPageWidthPt: pageWidthPt, pageFrame: frame,
                )
            }
            y += size.height + pageGap
        }
        return nil
    }

    private func pageStack(contentWidth: CGFloat, zoom: CGFloat) -> some View {
        VStack(spacing: pageGap) {
            ForEach(0 ..< pageSizes.count, id: \.self) { index in
                pageView(index: index, zoom: zoom)
            }
        }
        .padding(.top, topInset)
        .frame(width: contentWidth, alignment: .center)
    }

    @ViewBuilder
    private func pageView(index: Int, zoom: CGFloat) -> some View {
        let size = pageSizes[index]
        if let page = document.page(at: index), size.width > 0, size.height > 0 {
            let z = max(zoom, 0.01)
            // Rasterize the vector page at its on-screen size (natural × committed zoom), then pre-scale 1/zoom into
            // the natural-sized layout slot so the stack's `scaleEffect(zoom)` cancels it; the page then renders 1:1
            // with its raster — sharp at the committed zoom. A plain `scaleEffect` on a `withCGContext` Canvas
            // upscales the bitmap and blurs (not re-rasterized under the transform); same trick `PDFPageView` uses
            // for page mode. The live `magnification` is still a plain scaleEffect on top — transient blur during a
            // pinch, re-sharpened on commit when `zoom` updates.
            PDFPageCanvas(page: page)
                .frame(width: size.width * z, height: size.height * z)
                .scaleEffect(1 / z, anchor: .topLeading)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
        } else {
            Color(.secondarySystemBackground)
                .frame(width: max(size.width, 1), height: max(size.height, 1))
        }
    }
}
#endif
