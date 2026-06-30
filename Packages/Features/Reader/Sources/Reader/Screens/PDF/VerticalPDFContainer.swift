import Domain
import PDFKit
import PencilKit
import SheetMusicCore
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

    /// User opt-out for playback follow. When on (default), the scroll keeps the playing cursor in view; when off,
    /// the cursor still draws but only manual operations recenter.
    @AppStorage(ReaderGlobalSettingsKey.autoFollowEnabled)
    private var autoFollowEnabled = true

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
            // Keep the playing cursor on screen, honoring the auto-follow opt-out (mirrors the score vertical reader).
            .onChange(of: cursorFollowKey) { old, new in
                followPlaybackScroll(old: old, new: new, viewport: viewport, sizes: sizes)
            }
        }
    }

    /// The cursors whose change drives auto-scroll: the live display cursor plus its scroll-lookahead anchor.
    private var cursorFollowKey: [ScoreCursor?] {
        [viewModel.playbackSession.displayCursor, viewModel.playbackSession.scrollAnchorCursor]
    }

    /// Auto-scroll the playing cursor into view on a cursor change, subject to the shared follow gate.
    private func followPlaybackScroll(old: [ScoreCursor?], new: [ScoreCursor?], viewport: CGSize, sizes: [CGSize]) {
        guard readerShouldFollowPlayback(
            autoFollowEnabled: autoFollowEnabled,
            isPlaybackDriven: viewModel.playbackSession.scrollAnchorCursor != nil,
            cursorMoved: old[0] != new[0],
        ) else { return }
        autoScroll(
            realCursor: viewModel.playbackSession.displayCursor,
            lookaheadCursor: viewModel.playbackSession.scrollAnchorCursor,
            viewport: viewport,
            sizes: sizes,
        )
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

    // MARK: Playback follow

    /// Keep the playing cursor (and its lookahead) on screen, scaling content-space coords into the live scroll
    /// space and reusing the shared keep-in-view follow logic (`scrollOffsetKeepingInView`).
    private func autoScroll(
        realCursor: ScoreCursor?,
        lookaheadCursor: ScoreCursor?,
        viewport: CGSize,
        sizes: [CGSize],
    ) {
        guard let realCursor, let realRect = cursorContentRect(for: realCursor, sizes: sizes) else { return }
        let cw = sizes.map(\.width).max() ?? 0
        guard cw > 0 else { return }
        let zoom = viewModel.viewportZoom * (viewport.width / cw)
        let pad: CGFloat = 24 * zoom
        let targetMinY = realRect.minY * zoom
        // Anticipate by keeping the lookahead's bottom in view during playback; falls back to the real cursor.
        let lookRect = lookaheadCursor.flatMap { cursorContentRect(for: $0, sizes: sizes) }
        let targetMaxY = (lookRect?.maxY ?? realRect.maxY) * zoom
        let curY = liveScrollOffset.y
        let newY = CGFloat(scrollOffsetKeepingInView(
            current: Double(curY),
            targetMin: Double(targetMinY),
            targetMax: Double(targetMaxY),
            viewport: Double(viewport.height),
            pad: Double(pad),
        ))
        guard abs(newY - curY) >= 0.5 else { return }
        pendingScroll = .animated(CGPoint(x: liveScrollOffset.x, y: newY))
    }

    /// The cursor's rect in UNZOOMED content space — its page's stacked position plus its in-page rect — or `nil`.
    private func cursorContentRect(for cursor: ScoreCursor, sizes: [CGSize]) -> CGRect? {
        guard let rect = viewModel.pdfCursorRect(for: cursor) else { return nil }
        let frames = pageFrames(sizes: sizes)
        guard frames.indices.contains(rect.pageIndex) else { return nil }
        let pageFrame = frames[rect.pageIndex]
        return CGRect(
            x: pageFrame.minX + rect.rect.minX,
            y: pageFrame.minY + rect.rect.minY,
            width: rect.rect.width,
            height: rect.rect.height,
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
        var y: CGFloat = 0
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
    private func contentRect(for cursor: PDFCursorRect, contentWidth: CGFloat) -> CGRect? {
        guard pageSizes.indices.contains(cursor.pageIndex) else { return nil }
        var y: CGFloat = 0
        for (index, size) in pageSizes.enumerated() {
            if index == cursor.pageIndex {
                let x = (contentWidth - size.width) / 2 + cursor.rect.minX
                return CGRect(x: x, y: y + cursor.rect.minY, width: cursor.rect.width, height: cursor.rect.height)
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
