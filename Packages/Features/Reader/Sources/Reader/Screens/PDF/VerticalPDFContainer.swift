import PDFKit
import PencilKit
import SwiftUI

/// Vertical-continuous PDF viewing. Pages are stacked at viewport width and scrolled vertically, riding the shared
/// `ScoreScrollHost` scroll/pinch infrastructure so zoom and gestures match the score reader. Distinct from the score
/// vertical *reflow* (PDFs are fixed-layout): here "vertical" just means a continuous scroll of fixed pages.
struct VerticalPDFContainer: View {
    let document: PDFDocument
    @Bindable var viewModel: ReaderViewModel

    @State private var provider: PDFPageProvider?
    @State private var contentOffset: CGPoint = .zero
    @State private var contentInsetTop: CGFloat = 0
    @State private var pendingScroll: ScoreScrollCommand?
    @State private var pinch = PinchState()
    @State private var committedZoom: CGFloat = 1
    /// The annotation model projected to the current page geometry (committed-zoom-scaled stack). Recomputed on load /
    /// page-count / committed-zoom change — NOT on scroll/pinch — and kept equal to the live ink while the user draws,
    /// so the canvas seed never round-trips and wipes an in-progress stroke. Passed to the canvas as the seed drawing.
    @State private var projectedAnnotations = PKDrawing()

    var body: some View {
        GeometryReader { geo in
            let provider = ensureProvider()
            let baseWidth = geo.size.width
            ScoreScrollHost(
                contentOffset: $contentOffset,
                contentInsetTop: $contentInsetTop,
                pendingScroll: $pendingScroll,
                alwaysBounceVertical: true,
                alwaysBounceHorizontal: false,
                centerVertically: false,
                centerHorizontally: true,
                expectedContentSize: { expectedSize(provider: provider, baseWidth: baseWidth) },
                onPinchBegan: { anchor, _ in
                    pinch.cancelResetAnimation()
                    pinch.anchor = anchor
                    pinch.magnification = 1
                },
                onPinchChanged: { scale, _ in pinch.magnification = scale },
                onPinchEnded: { scale, _, _ in
                    committedZoom = clampZoom(committedZoom * scale)
                    pinch.magnification = 1
                },
                annotationOverlay: annotationSpec(provider: provider, baseWidth: baseWidth),
            ) {
                pageStack(provider: provider, baseWidth: baseWidth)
                    .scaleEffect(pinch.magnification, anchor: pinch.anchor)
            }
            .onChange(of: committedZoom) { reproject(provider: provider, baseWidth: baseWidth) }
            .onChange(of: viewModel.annotationDrawings) { reproject(provider: provider, baseWidth: baseWidth) }
            .task(id: provider.pageCount) { reproject(provider: provider, baseWidth: baseWidth) }
        }
    }

    private func pageStack(provider: PDFPageProvider, baseWidth: CGFloat) -> some View {
        let width = baseWidth * committedZoom
        return VStack(spacing: 8) {
            ForEach(0 ..< provider.pageCount, id: \.self) { index in
                PDFPageImage(provider: provider, index: index, width: width)
            }
        }
    }

    private func expectedSize(provider: PDFPageProvider, baseWidth: CGFloat) -> CGSize {
        let width = baseWidth * committedZoom
        var height: CGFloat = 0
        for i in 0 ..< provider.pageCount {
            let size = provider.pageSize(i)
            height += size.height == 0 ? 0 : width * (size.height / size.width)
            height += 8
        }
        return CGSize(width: width, height: height)
    }

    /// Each page's frame in content space (committed-zoom-scaled stack coordinates) — the same frame `pageStack` lays
    /// the pages into. Capture and display both normalize against these, so ink tracks pages across zoom commits.
    /// Mirrors `expectedSize`'s height accumulation exactly (full width, 8pt gaps).
    private func pageFrames(provider: PDFPageProvider, baseWidth: CGFloat) -> [CGRect] {
        let width = baseWidth * committedZoom
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for i in 0 ..< provider.pageCount {
            let size = provider.pageSize(i)
            let height = size.width == 0 ? width : width * (size.height / size.width)
            frames.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height + 8
        }
        return frames
    }

    /// Opt-in annotation overlay config for the host. The `state` closure recomputes the canvas mirror geometry at call
    /// time (read by the host's scroll/pinch sync), so it tracks without a SwiftUI render round-trip. The pages lay out
    /// at the committed-zoom-scaled width and only the live `magnification` rides via `scaleEffect`, so the canvas's
    /// content space IS the committed-zoom-scaled stack: `documentSize` is that stack size and `zoomScale` is the live
    /// `magnification` only (committed zoom is already baked into the geometry).
    private func annotationSpec(provider: PDFPageProvider, baseWidth: CGFloat) -> AnnotationOverlaySpec {
        let frames = pageFrames(provider: provider, baseWidth: baseWidth)
        return AnnotationOverlaySpec(
            isAnnotating: viewModel.isAnnotating,
            isPencilPreferred: UIDevice.current.userInterfaceIdiom == .pad,
            displayDrawing: projectedAnnotations,
            onChange: { drawing in
                // The canvas is the source of truth while drawing: keep the displayed projection equal to the live ink
                // so the next render's `applyDrawing` is a no-op (mirrors `VerticalScoreContainer`). The model is still
                // captured for persistence; load / zoom-commit reproject from the model via `reproject`.
                projectedAnnotations = drawing
                viewModel.annotationDrawingsDidChange(
                    PDFAnnotationAnchoring.capture(strokes: drawing.strokes, pageFrames: frames),
                )
            },
            state: {
                let m = pinch.magnification
                let size = expectedSize(provider: provider, baseWidth: baseWidth) // committed-zoom-scaled stack
                let slack: CGFloat = 100_000
                return AnnotationCanvasState(
                    documentSize: size,
                    zoomScale: m,
                    contentOffsetBias: CGPoint(
                        x: -pinch.anchor.x * size.width * (1 - m),
                        y: -pinch.anchor.y * size.height * (1 - m),
                    ),
                    contentInset: UIEdgeInsets(top: slack, left: slack, bottom: slack, right: slack),
                )
            },
        )
    }

    private func reproject(provider: PDFPageProvider, baseWidth: CGFloat) {
        projectedAnnotations = PDFAnnotationAnchoring.display(
            viewModel.annotationDrawings,
            pageFrames: pageFrames(provider: provider, baseWidth: baseWidth),
        )
    }

    private func ensureProvider() -> PDFPageProvider {
        if let provider { return provider }
        let new = PDFPageProvider(document: document)
        DispatchQueue.main.async { provider = new }
        return new
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat {
        min(max(z, 1), 6)
    }
}

/// One page rendered at `width` points. Re-rasterizes via the provider whenever the on-screen width (× display scale)
/// changes, so content is sharp at the committed zoom level.
private struct PDFPageImage: View {
    let provider: PDFPageProvider
    let index: Int
    let width: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let size = provider.pageSize(index)
        let height = size.width == 0 ? width : width * (size.height / size.width)
        let targetScale = max(0.1, (width / max(size.width, 1)) * displayScale)
        return Group {
            if let cg = provider.image(pageIndex: index, targetScale: targetScale) {
                Image(decorative: cg, scale: displayScale).resizable()
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .frame(width: width, height: height)
    }
}
