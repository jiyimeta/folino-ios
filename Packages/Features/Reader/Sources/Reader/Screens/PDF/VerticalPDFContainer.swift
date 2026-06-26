import PDFKit
import PencilKit
import SwiftUI

/// Vertical-continuous PDF viewing. Pages are stacked top-to-bottom at their natural sizes; the whole stack is
/// fit-to-width and zoomed via `scaleEffect` (vector `PDFPageCanvas`, sharp at any zoom), riding the shared
/// `VerticalReaderShell` so scroll / pinch / annotation match the score vertical reader. "Vertical" here means a
/// continuous scroll of fixed pages — PDFs are fixed-layout, so there is no reflow.
///
/// Committed zoom is applied by `scaleEffect` (not baked into page widths), so the page geometry — and therefore the
/// annotation page frames — live in one UNZOOMED content space. This mirrors `VerticalZoomedSurface`'s composition
/// exactly, which lets the annotation canvas reuse the score vertical reader's proven pivot geometry.
struct VerticalPDFContainer: View {
    let document: PDFDocument
    @Bindable var viewModel: ReaderViewModel

    @State private var liveScrollOffset: CGPoint = .zero
    @State private var contentInsetTop: CGFloat = 0
    @State private var pendingScroll: ScoreScrollCommand?
    @State private var pinch = PinchState()
    @State private var pinchSession: VerticalPinchSession?
    /// Mirror of `viewModel.viewportZoom` set OUTSIDE `withAnimation` (by the shell's commit) so `expectedContentSize`
    /// reads the final committed value, not SwiftUI's interpolated values during a commit transition. Mirrors the score
    /// vertical container.
    @State private var committedZoom: CGFloat = 1
    /// The annotation model projected to the current (unzoomed) page geometry. Recomputed on load / appear — NOT on
    /// scroll / pinch / zoom — and kept equal to the live ink while the user draws, so the canvas seed never
    /// round-trips and wipes an in-progress stroke. Passed to the canvas as the seed drawing.
    @State private var projectedAnnotations = PKDrawing()

    /// Vertical gap between stacked pages, in unzoomed content points.
    private let pageGap: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size
            // Snapshot the page geometry once per render; the host-time closures below capture this stable value.
            let sizes = pageSizes()
            VerticalReaderShell(
                viewModel: viewModel,
                pinch: pinch,
                viewport: viewport,
                liveScrollOffset: $liveScrollOffset,
                contentInsetTop: $contentInsetTop,
                pendingScroll: $pendingScroll,
                committedZoom: $committedZoom,
                pinchSession: $pinchSession,
                expectedContentSize: { expectedSize(viewport: viewport, sizes: sizes) },
                annotationOverlay: annotationSpec(viewport: viewport, sizes: sizes),
                onPinchCommitDocWidth: { contentWidth(sizes: sizes) },
            ) {
                VerticalPDFSurface(
                    viewModel: viewModel,
                    pinch: pinch,
                    document: document,
                    viewport: viewport,
                    pageGap: pageGap,
                    pageSizes: sizes,
                )
            }
            // Reproject from the model on load (annotationDrawings populates async after the PDF appears) — but ONLY
            // when not annotating. While annotating, the canvas is the source of truth; reseeding from the
            // round-tripped model bytes would wipe the in-progress stroke. Page frames are unzoomed (fixed for the
            // document), so — unlike the old raster impl — no zoom-commit reproject is needed.
            .onChange(of: viewModel.annotationDrawings) {
                if !viewModel.isAnnotating { reproject(sizes: sizes) }
            }
            .onAppear { reproject(sizes: sizes) }
        }
    }

    // MARK: Page geometry (unzoomed content space)

    /// Natural mediaBox point sizes for every page, index-aligned with the document. `.zero` for an unreadable page.
    private func pageSizes() -> [CGSize] {
        (0 ..< document.pageCount).map { document.page(at: $0)?.bounds(for: .mediaBox).size ?? .zero }
    }

    /// The unzoomed content width — the widest page. Narrower pages are centered, preserving true relative page sizes.
    private func contentWidth(sizes: [CGSize]) -> CGFloat {
        sizes.map(\.width).max() ?? 0
    }

    /// The unzoomed stack size: width = widest page, height = Σ page heights + inter-page gaps.
    private func unzoomedStackSize(sizes: [CGSize]) -> CGSize {
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.reduce(0) { $0 + $1.height } + pageGap * CGFloat(max(0, sizes.count - 1))
        return CGSize(width: width, height: height)
    }

    /// Each page's frame in unzoomed content space (matching `VerticalPDFSurface`'s `VStack`: widest-page width,
    /// centered, `pageGap` between). Capture and display normalize against these, so ink tracks pages. Unzoomed because
    /// committed zoom is applied by `scaleEffect`, not baked into the geometry.
    private func pageFrames(sizes: [CGSize]) -> [CGRect] {
        let cw = sizes.map(\.width).max() ?? 0
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for size in sizes {
            frames.append(CGRect(x: (cw - size.width) / 2, y: y, width: size.width, height: size.height))
            y += size.height + pageGap
        }
        return frames
    }

    /// Fit-to-width factor mapping the unzoomed content width to the viewport. No upper cap — a small page scales up to
    /// fill the width, as a continuous PDF reader should.
    private func fitFactor(viewport: CGSize, sizes: [CGSize]) -> CGFloat {
        let cw = contentWidth(sizes: sizes)
        return cw > 0 ? viewport.width / cw : 1
    }

    private func expectedSize(viewport: CGSize, sizes: [CGSize]) -> CGSize {
        let stack = unzoomedStackSize(sizes: sizes)
        let zoom = committedZoom * fitFactor(viewport: viewport, sizes: sizes)
        return CGSize(width: stack.width * zoom, height: stack.height * zoom)
    }

    // MARK: Annotation

    private func annotationSpec(viewport: CGSize, sizes: [CGSize]) -> AnnotationOverlaySpec {
        let frames = pageFrames(sizes: sizes)
        return AnnotationOverlaySpec(
            isAnnotating: viewModel.isAnnotating,
            isPencilPreferred: UIDevice.current.userInterfaceIdiom == .pad,
            displayDrawing: projectedAnnotations,
            onChange: { drawing in
                // The canvas is the source of truth while drawing: keep the displayed projection equal to the live ink
                // so the next render's `applyDrawing` is a no-op (mirrors `VerticalScoreContainer`). The model is still
                // captured for persistence; load reprojects from the model via `reproject`.
                projectedAnnotations = drawing
                viewModel.annotationDrawingsDidChange(
                    PDFAnnotationAnchoring.capture(strokes: drawing.strokes, pageFrames: frames),
                )
            },
            state: { annotationCanvasState(viewport: viewport, sizes: sizes) },
        )
    }

    /// Mirror geometry for the annotation canvas, matching `VerticalScoreContainer.annotationCanvasState` with no
    /// padding (the page stack has none): `documentSize` is the unzoomed stack, `zoomScale` folds committed zoom × fit
    /// × live magnification, and the contentOffset bias reproduces the live pinch pivot. The host adds the scroll
    /// view's real contentOffset to the bias.
    private func annotationCanvasState(viewport: CGSize, sizes: [CGSize]) -> AnnotationCanvasState {
        let stack = unzoomedStackSize(sizes: sizes)
        guard stack.width > 0, stack.height > 0 else {
            return AnnotationCanvasState(
                documentSize: .zero, zoomScale: 1, contentOffsetBias: .zero, contentInset: .zero,
            )
        }
        let zoomC = viewModel.viewportZoom * fitFactor(viewport: viewport, sizes: sizes) // committed zoom, no live mag
        let m = pinch.magnification
        let z = zoomC * m
        let anchorTermX = pinch.anchor.x * stack.width * (1 - m) * zoomC
        let anchorTermY = pinch.anchor.y * stack.height * (1 - m) * zoomC
        // A large symmetric inset keeps the (anchor-shifted) contentOffset inside PencilKit's valid range so it is
        // never clamped during a pinch. The canvas's own pan is disabled, so the extra scroll range is unreachable.
        let slack: CGFloat = 100_000
        return AnnotationCanvasState(
            documentSize: stack,
            zoomScale: z,
            contentOffsetBias: CGPoint(x: -anchorTermX - pinch.offsetX, y: -anchorTermY),
            contentInset: UIEdgeInsets(top: slack, left: slack, bottom: slack, right: slack),
        )
    }

    private func reproject(sizes: [CGSize]) {
        projectedAnnotations = PDFAnnotationAnchoring.display(
            viewModel.annotationDrawings, pageFrames: pageFrames(sizes: sizes),
        )
    }
}

/// The hosted PDF page stack. A separate `View` (like `VerticalZoomedSurface`) so it reads `pinch.*` /
/// `viewModel.viewportZoom` directly and SwiftUI observation delivers animated commit updates inside the
/// `ScoreScrollHost`, rather than through `rootView` reassignment (which drops the animation transaction). Pages are
/// laid out at their natural sizes; the committed zoom × fit-to-width scale is applied here via `scaleEffect`, matching
/// `VerticalZoomedSurface` so the annotation overlay's pivot geometry is identical.
private struct VerticalPDFSurface: View {
    @Bindable var viewModel: ReaderViewModel
    @Bindable var pinch: PinchState
    let document: PDFDocument
    let viewport: CGSize
    let pageGap: CGFloat
    let pageSizes: [CGSize]

    var body: some View {
        let cw = pageSizes.map(\.width).max() ?? 0
        let stackHeight = pageSizes.reduce(0) { $0 + $1.height } + pageGap * CGFloat(max(0, pageSizes.count - 1))
        let zoom = cw > 0 ? viewModel.viewportZoom * (viewport.width / cw) : viewModel.viewportZoom
        return pageStack(contentWidth: cw)
            .scaleEffect(pinch.magnification, anchor: pinch.anchor)
            .scaleEffect(zoom, anchor: .topLeading)
            .offset(x: pinch.offsetX, y: 0)
            .frame(width: cw * zoom, height: stackHeight * zoom, alignment: .topLeading)
    }

    private func pageStack(contentWidth: CGFloat) -> some View {
        VStack(spacing: pageGap) {
            ForEach(0 ..< pageSizes.count, id: \.self) { index in
                pageView(index: index)
            }
        }
        .frame(width: contentWidth, alignment: .center)
    }

    @ViewBuilder
    private func pageView(index: Int) -> some View {
        let size = pageSizes[index]
        if let page = document.page(at: index), size.width > 0, size.height > 0 {
            PDFPageCanvas(page: page)
                .frame(width: size.width, height: size.height)
        } else {
            Color(.secondarySystemBackground)
                .frame(width: max(size.width, 1), height: max(size.height, 1))
        }
    }
}
