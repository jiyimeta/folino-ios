// swiftlint:disable file_length
// PagedPDFContainer mirrors PagedScoreContainer's page-band pagination / pinch / annotation-overlay plumbing for
// paged PDF viewing; the parallel structure keeps it just over the file_length budget.

// PARITY(macos): paged layout for an imported PDF — `MacOriginalPDFView` shows an imported PDF in one continuous
//   layout only, with the playback cursor and committed ink over it. There is no paged mode for a PDF on the Mac,
//   so `ReaderLayoutMode` silently means nothing while an original is on screen there. What macOS needs is a Mac
//   page deck for PDF pages — `MacPageDeck` is the shape, over `PDFPage` rather than an engraved system.

#if os(iOS)
import Domain
import PDFKit
import PencilKit
import ReaderAnnotationCore
import SheetMusicCore
import SwiftUI

/// Page-by-page PDF viewing. Each physical PDF page maps to one reader page. Navigation, zoom, slide/swipe/pinch, and
/// tap-zone behaviour are identical to `PagedScoreContainer` — both feed the shared `PagedReaderSurface`.
/// Score-specific parts (LayoutDocument, cursor follow, layout rebuild, AB-loop) are absent; page count comes directly
/// from `document.pageCount`.
///
/// Pinch composition matches `PagedScoreContainer` (same `committedZoom`, two `scaleEffect`s, snap-to-unit commit).
struct PagedPDFContainer: View {
    let document: PDFDocument
    /// User opt-out: when false, the page-turn tap zones are hidden (swipe still works).
    let showsPageTurnButtons: Bool
    @Bindable var viewModel: ReaderViewModel

    /// Page index + swipe-drag state — `@Observable` reference so `withAnimation` transactions reach the
    /// `ScoreScrollHost`-hosted subtree via observation rather than through `rootView` reassignment (which drops them).
    @State var pageState = PageState()
    @State var liveScrollOffset: CGPoint = .zero
    @State var pinchSession: PinchSession?
    @State var pendingScroll: ScoreScrollCommand?
    @State var contentInsetTop: CGFloat = 0
    @State var pinch = PinchState()
    @State var committedZoom: CGFloat = 1.0
    /// The annotation model for the CURRENT PDF page, projected to band space. Reseeded on page/model change; kept
    /// equal to the live ink while drawing so the canvas seed never round-trips an in-progress stroke.
    @State var projectedAnnotations = PKDrawing()
    /// The current page-band viewport, mirrored from the body so the `withAnimation` page-turn commits (which run
    /// outside the body and have no `proxy`) can reseed the live annotation canvas synchronously — see
    /// `commitPageTurn` / `commitDragTurn`.
    @State var lastViewport: CGSize = .zero
    /// Stable handle for imperatively reseeding the live annotation canvas at a page-turn commit (see
    /// `AnnotationCanvasHandle`) — used by `reseedLiveCanvasForPageTurn`.
    @State var annotationHandle = AnnotationCanvasHandle()

    /// First-tap onboarding hint state. `false` until the user touches any page-nav zone for the first time, then
    /// permanently `true`. See `ReaderGlobalSettingsKey.pageTapHintDismissed`.
    @AppStorage(ReaderGlobalSettingsKey.pageTapHintDismissed)
    var pageTapHintDismissed = false

    /// User opt-out for playback follow. When on (default), the page turns to keep the playing cursor in view; when
    /// off, the cursor still draws but the page only turns from manual gestures.
    @AppStorage(ReaderGlobalSettingsKey.autoFollowEnabled)
    private var autoFollowEnabled = true

    /// Insets that position the page band inside the full-screen scroll host: top includes the parent's inset from
    /// the Reader's self-drawn top bar so the band clears it; the other edges are
    /// the raw system insets. Sampled from a sibling reader that ignores the safe area so the values stay correct even
    /// when the scroll host itself is full-bleed.
    @State var pageInsets: EdgeInsets = .init()

    struct PinchSession {
        var baseZoom: CGFloat
    }

    /// Curve applied when mutating `pageState.pageIndex` — every page's `.offset` depends on `pageIndex`, so this curve
    /// governs every page's slide.
    static let pageTransitionAnimation: Animation = .easeOut(duration: 0.18)

    /// Named coordinate space for the per-page tap-to-seek gesture (the page's own band rect).
    static let seekSpace = "pdfPageSeek"

    var body: some View {
        // Outer `GeometryReader` honors the Reader's self-drawn top bar's inset and the system insets,
        // so `proxy.size` is the visible page band at zoom 1. The scroll host itself is full-bleed; the hosted surface
        // pads by `pageInsets` so it lands inside this same rect — pinch zoom can then expand past the safe area.
        GeometryReader { proxy in
            let viewportWidth = proxy.size.width
            let viewportHeight = proxy.size.height
            let viewport = CGSize(width: viewportWidth, height: viewportHeight)
            scrollContent(viewport: viewport)
                // Mirror the live viewport so the out-of-body page-turn commits can reseed the annotation canvas
                // synchronously. `initial: true` seeds the first layout; it then tracks rotation / resize.
                    .onChange(of: viewport, initial: true) { _, newValue in lastViewport = newValue }
        }
        .background {
            // Sibling reader extending past the safe area so its `proxy.safeAreaInsets` still reflects the chrome the
            // main GR was inset by. Top includes the self-drawn top bar; the other edges are raw system insets.
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: EdgeInsets.self) { proxy in
                    proxy.safeAreaInsets
                } action: { newValue in
                    pageInsets = newValue
                }
        }
    }

    // swiftlint:disable:next function_body_length
    private func scrollContent(viewport: CGSize) -> some View {
        // Observe live magnification so each frame of a commit-reset ease re-renders this view → the host re-syncs the
        // annotation canvas, keeping the ink locked to the page through the eased zoom commit (see PinchState).
        _ = pinch.magnification
        // Observe the annotation model so a change (load, capture, cross-mode edit) re-renders here and reassigns the
        // hosted surface's rootView — otherwise the hosted static ink layers keep a stale (often empty) model.
        _ = viewModel.annotationDrawings
        // Same reason for the playback cursor: observe it here so each cursor change reassigns the hosted surface's
        // rootView and the current page redraws the on-PDF cursor bar.
        _ = viewModel.pdfDisplayCursorRect
        return ScoreScrollHost(
            contentOffset: $liveScrollOffset,
            contentInsetTop: $contentInsetTop,
            pendingScroll: $pendingScroll,
            alwaysBounceVertical: false,
            alwaysBounceHorizontal: false,
            centerVertically: false,
            centerHorizontally: false,
            expectedContentSize: {
                // Full-screen content area (= page band + insets) so pinch zoom can stretch the band into the chrome
                // regions. Padding lives inside the hosted surface and scales with zoom.
                CGSize(
                    width: (viewport.width + pageInsets.leading + pageInsets.trailing)
                        * committedZoom,
                    height: (viewport.height + pageInsets.top + pageInsets.bottom)
                        * committedZoom,
                )
            },
            onPinchBegan: { anchor, _ in
                pinch.cancelResetAnimation() // don't let a trailing commit ease fight the new gesture
                pinchSession = PinchSession(baseZoom: viewModel.viewportZoom)
                pinch.anchor = anchor
                pinch.magnification = 1.0
                pinch.offsetX = 0
                pinch.offsetY = 0
            },
            onPinchChanged: { magnification, translation in
                pinch.magnification = magnification
                pinch.offsetX = translation.x
                pinch.offsetY = translation.y
            },
            onPinchEnded: { magnification, startLocation, currentOffset in
                commitPinch(
                    magnification: magnification,
                    startLocation: startLocation,
                    currentOffset: currentOffset,
                    viewport: viewport,
                )
            },
            onUserViewportInteractionBegan: {
                viewModel.playbackSession.suspendPlaybackFollowForManualViewportChange()
            },
            annotationOverlay: annotationSpec(viewport: viewport),
        ) {
            PagedReaderSurface(
                viewModel: viewModel,
                pinch: pinch,
                pageState: pageState,
                viewport: viewport,
                pageInsets: pageInsets,
                pageCount: document.pageCount,
                onPrevPage: { goToPage(delta: -1) },
                onNextPage: { goToPage(delta: +1) },
                onFirstPage: { goToFirstPage() },
                onLastPage: { goToLastPage() },
                onSwipeChanged: { tx in
                    onSwipeChanged(translationX: tx, viewportWidth: viewport.width)
                },
                onSwipeEnded: { tx, pred, vel in
                    onSwipeEnded(
                        translationX: tx,
                        predictedEndX: pred,
                        velocityX: vel,
                        viewportWidth: viewport.width,
                    )
                },
                // Suppress the onboarding hint while annotating so the dashed preview doesn't sit over the drawing
                // surface; it returns (if not permanently dismissed) once drawing stops.
                showsHint: !pageTapHintDismissed && !viewModel.isAnnotating,
                onAnyZoneTouchDown: { pageTapHintDismissed = true },
                showsTapZones: showsPageTurnButtons,
                pageContent: { idx in pdfPage(idx, viewport: viewport) },
            )
        }
        // Full-bleed so pinch zoom can stretch the page band beyond the safe area; the hosted surface re-applies
        // `pageInsets` as padding so the band sits inside the safe area at zoom 1.
        .ignoresSafeArea()
        .onChange(of: pageState.pageIndex) { _, _ in reprojectCurrentPage(viewport: viewport) }
        .onChange(of: viewModel.annotationDrawings) { _, _ in
            if !viewModel.isAnnotating {
                reprojectCurrentPage(viewport: viewport)
            }
        }
        // Entering/leaving annotation hands the current page off between its static layer and the live canvas.
        .onChange(of: viewModel.isAnnotating) { _, _ in reprojectCurrentPage(viewport: viewport) }
        // Turn to the page the playing cursor (or its lookahead) sits on, honoring the auto-follow opt-out.
        .onChange(of: pageFollowKey) { old, new in
            guard readerShouldFollowPlayback(
                autoFollowEnabled: autoFollowEnabled,
                isPlaybackDriven: viewModel.playbackSession.pageAnchorCursor != nil,
                cursorMoved: old[0] != new[0],
                followSuspended: viewModel.playbackSession.isPlaybackFollowSuspended,
            ) else { return }
            followPlaybackToPage(viewModel.playbackSession.pageAnchorCursor ?? viewModel.playbackSession.displayCursor)
        }
        .onAppear { reprojectCurrentPage(viewport: viewport) }
    }

    /// A page's frame in band (viewport) space: the page fitted into the viewport (preserving aspect) and centered —
    /// identical to `PDFPageView`'s composition, so ink normalizes against exactly the rendered page rect.
    private func pageFrame(forPage idx: Int, viewport: CGSize) -> CGRect? {
        let index = min(max(idx, 0), max(document.pageCount - 1, 0))
        guard let page = document.page(at: index) else { return nil }
        let b = page.bounds(for: .mediaBox).size
        guard b.width > 0, b.height > 0, viewport.width > 0, viewport.height > 0 else { return nil }
        let fit = min(viewport.width / b.width, viewport.height / b.height)
        let w = b.width * fit
        let h = b.height * fit
        return CGRect(x: (viewport.width - w) / 2, y: (viewport.height - h) / 2, width: w, height: h)
    }

    private func currentPageFrame(viewport: CGSize) -> CGRect? {
        pageFrame(forPage: pageState.pageIndex, viewport: viewport)
    }

    private func annotationSpec(viewport: CGSize) -> AnnotationOverlaySpec {
        AnnotationOverlaySpec(
            isAnnotating: viewModel.isAnnotating,
            isPencilPreferred: UIDevice.current.userInterfaceIdiom == .pad,
            canvasSession: viewModel.annotationCanvasSession,
            displayDrawing: projectedAnnotations,
            onChange: { drawing in
                // Capture ONLY while annotating. Leaving annotation empties the live canvas (static layers take over),
                // and `canvas.drawing = empty` fires `canvasViewDrawingDidChange` — recapturing the empty canvas here
                // would wipe this page's committed anchors. See `PagedScoreContainer`.
                guard viewModel.isAnnotating, let frame = currentPageFrame(viewport: viewport) else { return }
                let idx = min(max(pageState.pageIndex, 0), max(document.pageCount - 1, 0))
                projectedAnnotations = drawing // canvas is source of truth this page
                let (_, offPage) = PDFAnnotationAnchoring.partitionByPage(viewModel.annotationDrawings, pageIndex: idx)
                let captured = PDFAnnotationAnchoring.capturePage(
                    strokes: drawing.strokes, pageIndex: idx, pageFrame: frame,
                )
                viewModel.annotationDrawingsDidChange(offPage + captured)
            },
            state: { annotationCanvasState(viewport: viewport) },
            handle: annotationHandle,
        )
    }

    /// Mirror the current page band onto the viewport-pinned canvas — same composition as `PagedScoreContainer`
    /// (band documentSize = viewport, band offset by `pageInsets`, zoom = `viewportZoom × magnification`, live pan on
    /// both axes). PDF page mode uses `viewModel.viewportZoom` directly (the value `PDFPageView` is told to scale by).
    private func annotationCanvasState(viewport: CGSize) -> AnnotationCanvasState {
        let zoomC = viewModel.viewportZoom
        let m = pinch.magnification
        let z = zoomC * m
        let padX = pageInsets.leading
        let padY = pageInsets.top
        let paddedW = viewport.width + pageInsets.leading + pageInsets.trailing
        let paddedH = viewport.height + pageInsets.top + pageInsets.bottom
        let anchorTermX = pinch.anchor.x * paddedW * (1 - m) * zoomC
        let anchorTermY = pinch.anchor.y * paddedH * (1 - m) * zoomC
        let slack: CGFloat = 100_000
        return AnnotationCanvasState(
            documentSize: CGSize(width: viewport.width, height: viewport.height),
            zoomScale: z,
            contentOffsetBias: CGPoint(
                x: -padX * z - anchorTermX - pinch.offsetX,
                y: -padY * z - anchorTermY - pinch.offsetY,
            ),
            contentInset: UIEdgeInsets(top: slack, left: slack, bottom: slack, right: slack),
        )
    }

    /// Not `private`: reactive reseed points (pageIndex / isAnnotating / model change) call this.
    func reprojectCurrentPage(viewport: CGSize) {
        projectedAnnotations = projectedDrawing(viewport: viewport)
    }

    /// The current page's annotation model projected to band space, or an empty drawing when not annotating / no
    /// resolvable page frame (which force-clears the live canvas — see `reseedLiveCanvasForPageTurn`).
    private func projectedDrawing(viewport: CGSize) -> PKDrawing {
        guard viewModel.isAnnotating, let frame = currentPageFrame(viewport: viewport) else {
            return PKDrawing()
        }
        let idx = min(max(pageState.pageIndex, 0), max(document.pageCount - 1, 0))
        return PDFAnnotationAnchoring.displayPage(
            viewModel.annotationDrawings, pageIndex: idx, pageFrame: frame,
        )
    }

    /// Reseed the viewport-pinned live canvas to the current page synchronously at a page-turn commit. See
    /// `PagedScoreContainer.reseedLiveCanvasForPageTurn` for the full rationale — same imperative-echo-suppression
    /// fix, mirrored for the PDF page geometry.
    func reseedLiveCanvasForPageTurn(viewport: CGSize) {
        let drawing = projectedDrawing(viewport: viewport)
        projectedAnnotations = drawing
        annotationHandle.reseedForPageTurn(drawing)
    }

    private func commitPinch(
        magnification: CGFloat,
        startLocation: CGPoint,
        currentOffset: CGPoint,
        viewport: CGSize,
    ) {
        let session = pinchSession ?? PinchSession(baseZoom: viewModel.viewportZoom)
        pinchSession = nil

        let r = ReaderPinchCommit.resolve(PinchCommitInput(
            baseZoom: session.baseZoom, magnification: magnification,
            startLocation: startLocation, currentOffset: currentOffset,
            offsetX: pinch.offsetX, offsetY: pinch.offsetY,
        ))
        // Clamp the anchor-preserving target into the post-commit valid range and keep the residual the clamp removed.
        // Both axes ride `pinch.offset` in paged mode, so the residual is fully animatable: seed it into the live
        // offset to hold the content where the finger released it, then ease to zero so it settles at the edge-aligned
        // rest instead of snapping there. Content area = page band + safe-area insets scaled by the committed zoom; the
        // full-bleed host's bounds equal that padded band at zoom 1. Size is computed explicitly rather than through
        // the `expectedContentSize` closure, which reads the `committedZoom` we are about to mutate.
        let paddedBounds = CGSize(
            width: viewport.width + pageInsets.leading + pageInsets.trailing,
            height: viewport.height + pageInsets.top + pageInsets.bottom,
        )
        let contentSize = CGSize(width: paddedBounds.width * r.targetZoom, height: paddedBounds.height * r.targetZoom)
        let (clamped, residual) = ReaderPinchCommit.clampScrollTarget(
            r.rawScrollTarget, contentSize: contentSize, bounds: paddedBounds,
            insetLeft: 0, insetRight: 0, insetTop: 0, insetBottom: 0,
        )

        if r.isBounceBack {
            // Ease frame-by-frame (CADisplayLink) so the annotation ink overlay follows the rubber-band release in
            // lockstep instead of snapping ahead — see PinchState. (Was `withAnimation`, which the ink couldn't track.)
            pinch.animateReset(toMagnification: 1.0, offsetX: 0, offsetY: 0)
        } else {
            committedZoom = r.targetZoom
            pendingScroll = .immediate(clamped)
            if r.snapToUnit {
                viewModel.resetZoom()
                pinch.magnification = r.compensatedMag
                // Hold at release (seed the residual) then co-ease magnification and offset on one CADisplayLink. For
                // snap the range collapses to the origin, so the residual is `-rawScrollTarget`, which also absorbs the
                // live pan the raw target subtracted.
                pinch.offsetX = residual.x
                pinch.offsetY = residual.y
                pinch.animateReset(toMagnification: 1.0, offsetX: 0, offsetY: 0)
            } else {
                viewModel.viewportZoom = r.targetZoom
                pinch.magnification = 1.0
                pinch.anchor = .center
                if residual == .zero {
                    // Seamless fast path: the anchor-preserving target was already in range — nothing to ease.
                    pinch.offsetX = 0
                    pinch.offsetY = 0
                } else {
                    // Overscrolled past a content edge: hold at release, then ease to the edge-aligned rest. The ease
                    // rewrites `magnification` every frame (even at a constant 1.0), so the container's observation
                    // re-fires and re-syncs the ink overlay in lockstep with the offset.
                    pinch.offsetX = residual.x
                    pinch.offsetY = residual.y
                    pinch.animateReset(toMagnification: 1.0, offsetX: 0, offsetY: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func pdfPage(_ idx: Int, viewport: CGSize) -> some View {
        let index = min(max(idx, 0), max(document.pageCount - 1, 0))
        if let page = document.page(at: index) {
            PDFPageView(page: page, viewport: viewport, zoom: viewModel.viewportZoom)
                // Committed ink as a static layer that rides the page so it slides on a turn; hidden for the page being
                // actively annotated (the viewport-pinned live canvas owns it).
                    .overlay(alignment: .topLeading) { pageInkLayer(forPage: index, viewport: viewport) }
                    // Playback cursor for a parsed PDF, projected from original-PDF coords into this page's band rect.
                    .overlay(alignment: .topLeading) { pageCursorLayer(forPage: index, viewport: viewport) }
                    // Tap-to-seek: a center tap maps back to a Score cursor. Sits behind the page-turn tap zones (which
                    // own the left/right edges), so edge taps still turn pages.
                    .coordinateSpace(name: Self.seekSpace)
                    .gesture(pageSeekGesture(forPage: index, viewport: viewport))
        } else {
            Color.white.frame(width: viewport.width, height: viewport.height)
        }
    }

    /// The on-PDF playback cursor for `idx`, when this page is the one the live cursor is on. Projects the cursor's
    /// original-PDF (top-left mediaBox) rect into band space through the shared `PDFCursorProjection` — the same
    /// entry point Android's surfaces reach over JNI — against the same fitted + centered `pageFrame` the page itself
    /// is drawn in, so it lands exactly over the rendered page and rides the surface's zoom / pan.
    @ViewBuilder
    private func pageCursorLayer(forPage idx: Int, viewport: CGSize) -> some View {
        if let cursor = viewModel.pdfDisplayCursorRect, cursor.pageIndex == idx,
           let frame = pageFrame(forPage: idx, viewport: viewport),
           let pageSize = viewModel.pdfPlaybackData?.geometry.pageSizes[idx],
           let bandRect = PDFCursorProjection.displayRect(
               cursorRect: cursor.rect, geometryPageWidthPt: pageSize.width, pageFrame: frame,
           )
        {
            Rectangle()
                .fill(PDFPlaybackCursor.color)
                .frame(width: bandRect.width, height: bandRect.height)
                .offset(x: bandRect.minX, y: bandRect.minY)
                .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
                .allowsHitTesting(false)
        }
    }

    /// The cursors whose change drives auto-page-turn: the live display cursor plus its page-lookahead anchor.
    private var pageFollowKey: [ScoreCursor?] {
        [viewModel.playbackSession.displayCursor, viewModel.playbackSession.pageAnchorCursor]
    }

    /// Turn to the page that `cursor` resolves to on the original PDF (no-op while dragging, or when already there).
    private func followPlaybackToPage(_ cursor: ScoreCursor?) {
        guard !pageState.isDragging,
              let cursor,
              let page = viewModel.pdfCursorRect(for: cursor)?.pageIndex,
              page != pageState.pageIndex else { return }
        commitPageTurn(to: page)
    }

    /// Map a tap on page `idx` to a Score cursor (via the geometry's hit-test) and seek there. No-op when the PDF
    /// isn't playable, while annotating, off the current page, or outside the rendered page rect.
    private func pageSeekGesture(forPage idx: Int, viewport: CGSize) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named(Self.seekSpace)).onEnded { value in
            guard !viewModel.isAnnotating, idx == pageState.pageIndex,
                  let geometry = viewModel.pdfPlaybackData?.geometry,
                  let frame = pageFrame(forPage: idx, viewport: viewport),
                  let pageSize = geometry.pageSizes[idx], pageSize.width > 0,
                  frame.contains(value.location) else { return }
            let fit = frame.width / pageSize.width
            let inPage = CGPoint(
                x: (value.location.x - frame.minX) / fit,
                y: (value.location.y - frame.minY) / fit,
            )
            guard let cursor = geometry.cursor(at: inPage, pageIndex: idx) else { return }
            viewModel.playbackSession.setManualCursor(cursor)
        }
    }

    @ViewBuilder
    private func pageInkLayer(forPage idx: Int, viewport: CGSize) -> some View {
        if !(viewModel.isAnnotating && idx == pageState.pageIndex),
           let frame = pageFrame(forPage: idx, viewport: viewport)
        {
            StaticInkLayer(drawing: PDFAnnotationAnchoring.displayPage(
                viewModel.annotationDrawings, pageIndex: idx, pageFrame: frame,
            ), size: viewport)
        }
    }
}
#endif
