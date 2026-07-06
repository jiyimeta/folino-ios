import Domain
import PDFKit
import PencilKit
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

    /// First-tap onboarding hint state. `false` until the user touches any page-nav zone for the first time, then
    /// permanently `true`. See `ReaderGlobalSettingsKey.pageTapHintDismissed`.
    @AppStorage(ReaderGlobalSettingsKey.pageTapHintDismissed)
    var pageTapHintDismissed = false

    /// User opt-out for playback follow. When on (default), the page turns to keep the playing cursor in view; when
    /// off, the cursor still draws but the page only turns from manual gestures.
    @AppStorage(ReaderGlobalSettingsKey.autoFollowEnabled)
    private var autoFollowEnabled = true

    /// Insets that position the page band inside the full-screen scroll host: top includes the parent's
    /// `safeAreaPadding(.top, ReaderTopOverlay.height)` so the band clears the navigation chrome; the other edges are
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
        // Outer `GeometryReader` honors parent's `safeAreaPadding(.top, ReaderTopOverlay.height)` and system insets,
        // so `proxy.size` is the visible page band at zoom 1. The scroll host itself is full-bleed; the hosted surface
        // pads by `pageInsets` so it lands inside this same rect — pinch zoom can then expand past the safe area.
        GeometryReader { proxy in
            let viewportWidth = proxy.size.width
            let viewportHeight = proxy.size.height
            let viewport = CGSize(width: viewportWidth, height: viewportHeight)
            scrollContent(viewport: viewport)
        }
        .background {
            // Sibling reader extending past the safe area so its `proxy.safeAreaInsets` still reflects the chrome the
            // main GR was inset by. Top includes `ReaderTopOverlay`'s reserve; the other edges are raw system insets.
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
            if !viewModel.isAnnotating { reprojectCurrentPage(viewport: viewport) }
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

    private func reprojectCurrentPage(viewport: CGSize) {
        // Live canvas shows ink only while annotating; static layers in `pdfPage` cover display for every page.
        // Empty the live canvas when not annotating.
        guard viewModel.isAnnotating, let frame = currentPageFrame(viewport: viewport) else {
            projectedAnnotations = PKDrawing(); return
        }
        let idx = min(max(pageState.pageIndex, 0), max(document.pageCount - 1, 0))
        projectedAnnotations = PDFAnnotationAnchoring.displayPage(
            viewModel.annotationDrawings, pageIndex: idx, pageFrame: frame,
        )
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
        let scrollToTarget = CGPoint(x: max(0, r.rawScrollTarget.x), y: max(0, r.rawScrollTarget.y))

        if r.isBounceBack {
            // Ease frame-by-frame (CADisplayLink) so the annotation ink overlay follows the rubber-band release in
            // lockstep instead of snapping ahead — see PinchState. (Was `withAnimation`, which the ink couldn't track.)
            pinch.animateReset(toMagnification: 1.0, offsetX: 0, offsetY: 0)
        } else {
            committedZoom = r.targetZoom
            pendingScroll = .immediate(scrollToTarget)
            if r.snapToUnit {
                viewModel.resetZoom()
                pinch.magnification = r.compensatedMag
                pinch.animateReset(toMagnification: 1.0, offsetX: 0, offsetY: 0)
            } else {
                viewModel.viewportZoom = r.targetZoom
                pinch.magnification = 1.0
                pinch.anchor = .center
                pinch.offsetX = 0
                pinch.offsetY = 0
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
    /// original-PDF (top-left mediaBox) rect into band space by the same fit + centering `pageFrame` uses, so it lands
    /// exactly over the rendered page and rides the surface's zoom / pan.
    @ViewBuilder
    private func pageCursorLayer(forPage idx: Int, viewport: CGSize) -> some View {
        if let cursor = viewModel.pdfDisplayCursorRect, cursor.pageIndex == idx,
           let frame = pageFrame(forPage: idx, viewport: viewport),
           let pageSize = viewModel.pdfPlaybackData?.geometry.pageSizes[idx], pageSize.width > 0
        {
            let fit = frame.width / pageSize.width
            let bandRect = CGRect(
                x: frame.minX + cursor.rect.minX * fit,
                y: frame.minY + cursor.rect.minY * fit,
                width: cursor.rect.width * fit,
                height: cursor.rect.height * fit,
            )
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
