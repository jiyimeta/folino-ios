// PARITY(macos): one of the Reader's iOS-only layout-mode screens, built on `VerticalReaderShell` / `PinchState`.
//   Ⅳ's Mac reading surface needs its own layout, not a port of this one — see the markers on those files.

#if os(iOS)
import Domain
import PDFKit
import PencilKit
import ReaderAnnotationCore
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
    /// Stable handle the canvas controller links itself into (see `AnnotationCanvasHandle`). Continuous-scroll mode
    /// has no page-turn commit, so nothing calls `reseedForPageTurn` here — the handle only satisfies the shared
    /// `AnnotationOverlaySpec` initializer.
    @State private var annotationHandle = AnnotationCanvasHandle()

    /// Vertical gap between stacked pages, in unzoomed content points.
    private let pageGap: CGFloat = 8

    /// Height of the chrome the scroll slides under — status bar plus the Reader's self-drawn top bar — in
    /// SCREEN points. Measured rather than assumed; it varies with orientation and device.
    @State private var topChromeInset: CGFloat = 0

    /// `topChromeInset` expressed in unzoomed content points, so the first page clears the top bar instead of running
    /// under it — the same courtesy the score reader's vertical mode extends.
    ///
    /// Divided by the fit factor because a PDF's content space is its mediaBox (a 595pt-wide page fitted into a 430pt
    /// viewport renders at ~0.72), unlike an engraved score, whose layout is already computed at the viewport width.
    /// Without the division the reserved gap would come out short by exactly that factor. Mirrored into state so the
    /// annotation geometry — reprojected outside the layout pass — reads the same value the pages were laid out with.
    @State private var topContentInset: CGFloat = 0

    /// User opt-out for playback follow. When on (default), the scroll keeps the playing cursor in view; when off,
    /// the cursor still draws but only manual operations recenter.
    @AppStorage(ReaderGlobalSettingsKey.autoFollowEnabled)
    private var autoFollowEnabled = true

    var body: some View {
        GeometryReader { geo in
            // Snapshot the page geometry once per render; the host-time closures below capture this stable value.
            reader(viewport: geo.size, sizes: pageSizes())
        }
    }

    private func reader(viewport: CGSize, sizes: [CGSize]) -> some View {
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
            onUserViewportInteractionBegan: {
                viewModel.playbackSession.suspendPlaybackFollowForManualViewportChange()
            },
        ) {
            VerticalPDFSurface(
                viewModel: viewModel,
                pinch: pinch,
                document: document,
                viewport: viewport,
                pageGap: pageGap,
                pageSizes: sizes,
                topInset: topContentInset,
            )
        }
        .background {
            // Sibling reader extending beyond the safe area (the shell's own reader sits inside it and reports
            // zero), so its top inset is the whole chrome the scroll slides under.
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    max(0, proxy.safeAreaInsets.top)
                } action: { newValue in
                    topChromeInset = newValue
                }
        }
        .onChange(of: derivedTopContentInset(viewport: viewport, sizes: sizes), initial: true) { _, newValue in
            topContentInset = newValue
            // The page frames just moved, so ink anchored to them has to be re-placed against the new geometry.
            if !viewModel.isAnnotating {
                reproject(sizes: sizes)
            }
        }
        // Reproject from the model on load (annotationDrawings populates async after the PDF appears) — but ONLY
        // when not annotating. While annotating, the canvas is the source of truth; reseeding from the
        // round-tripped model bytes would wipe the in-progress stroke. Page frames are unzoomed (fixed for the
        // document), so — unlike the old raster impl — no zoom-commit reproject is needed.
        .onChange(of: viewModel.annotationDrawings) {
            if !viewModel.isAnnotating {
                reproject(sizes: sizes)
            }
        }
        .onAppear { reproject(sizes: sizes) }
        // Keep the playing cursor on screen, honoring the auto-follow opt-out (mirrors the score vertical reader).
        .onChange(of: cursorFollowKey) { old, new in
            followPlaybackScroll(old: old, new: new, viewport: viewport, sizes: sizes)
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
            followSuspended: viewModel.playbackSession.isPlaybackFollowSuspended,
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

    /// The unzoomed stack size: width = widest page, height = top chrome inset + Σ page heights + inter-page gaps.
    private func unzoomedStackSize(sizes: [CGSize]) -> CGSize {
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.reduce(0) { $0 + $1.height } + pageGap * CGFloat(max(0, sizes.count - 1))
        return CGSize(width: width, height: height + topContentInset)
    }

    /// `topChromeInset` converted into this document's content space for the given viewport. Pure; the body mirrors
    /// the result into `topContentInset`.
    private func derivedTopContentInset(viewport: CGSize, sizes: [CGSize]) -> CGFloat {
        let fit = fitFactor(viewport: viewport, sizes: sizes)
        return fit > 0 ? topChromeInset / fit : 0
    }

    /// Each page's frame in unzoomed content space (matching `VerticalPDFSurface`'s `VStack`: widest-page width,
    /// centered, `pageGap` between). Capture and display normalize against these, so ink tracks pages. Unzoomed because
    /// committed zoom is applied by `scaleEffect`, not baked into the geometry.
    private func pageFrames(sizes: [CGSize]) -> [CGRect] {
        let cw = sizes.map(\.width).max() ?? 0
        var frames: [CGRect] = []
        var y: CGFloat = topContentInset
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
                // Only the PDF layer is re-captured; ink anchored to the notation stays as it is. See the mirror of
                // this comment in `VerticalScoreContainer` — committing a bare capture from either side deletes the
                // other side's drawings.
                viewModel.annotationDrawingsDidChange(AnnotationLayers.replacing(
                    .originalPDF,
                    in: viewModel.annotationDrawings,
                    with: PDFAnnotationAnchoring.capture(strokes: drawing.strokes, pageFrames: frames),
                ))
            },
            state: { annotationCanvasState(viewport: viewport, sizes: sizes) },
            handle: annotationHandle,
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
    /// Projected through the shared `PDFCursorProjection` (the same entry point Android reaches over JNI), so the
    /// side-car's page width — not an assumed 1:1 with PDFKit's mediaBox — sets the scale.
    private func cursorContentRect(for cursor: ScoreCursor, sizes: [CGSize]) -> CGRect? {
        guard let rect = viewModel.pdfCursorRect(for: cursor) else { return nil }
        let frames = pageFrames(sizes: sizes)
        guard frames.indices.contains(rect.pageIndex),
              let pageWidthPt = viewModel.pdfPlaybackData?.geometry.pageSizes[rect.pageIndex]?.width
        else { return nil }
        return PDFCursorProjection.displayRect(
            cursorRect: rect.rect, geometryPageWidthPt: pageWidthPt, pageFrame: frames[rect.pageIndex],
        )
    }
}
#endif
