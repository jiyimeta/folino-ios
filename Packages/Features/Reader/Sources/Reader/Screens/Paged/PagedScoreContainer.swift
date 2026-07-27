// swiftlint:disable file_length
// PagedScoreContainer hosts the page-band layout / pagination / pinch pipeline plus the annotation overlay and
// cursor-follow plumbing for the paged Reader; its breadth keeps it just over the file_length budget.

import Domain
import PencilKit
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Page-by-page Reader mode. Lays the score out at viewport width (same as `VerticalScoreContainer`), paginates the
/// resulting systems by viewport height, and shows one page at a time. The full `ScoreView` is drawn behind a
/// `.clipped()` band so tap-seek / playback cursor / AB-loop overlays continue to operate in full-document coordinates.
///
/// Pinch composition matches `VerticalScoreContainer` (see that file for the rationale on `committedZoom`, the two
/// `scaleEffect`s, and the snap-to-unit two-phase commit).
///
/// Navigation lives in `TapOverlay`: a leading / trailing column each `12 %` of the viewport, split `3 : 7` vertically
/// — the top slice jumps to the first / last page, the bottom slice turns one page in the same direction. A capsule
/// page-position badge fades in along with the zones. A page turn resets `viewportZoom` to `1` and `pendingScroll` to
/// the origin, then mutates `pageState.pageIndex` inside `withAnimation` so `PagedZoomedSurface` interpolates the
/// neighbor / edge `.offset`s into the slide / fade transition.
struct PagedScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let playbackCursor: ScoreCursor?
    /// Lookahead anchor (1 beat ahead) used to turn the page early — the page containing this cursor is made
    /// active. `nil` when not playing, in which case page-follow falls back to the real cursor (manual seek).
    let pageAnchorCursor: ScoreCursor?
    /// User opt-out: when false, continuous playback no longer auto-turns the page. Manual navigation (tap-seek,
    /// measure-step) still turns to keep its target visible (see `readerShouldFollowPlayback`).
    let autoFollowEnabled: Bool
    /// User opt-out: when false, the page-turn tap zones are hidden (swipe + auto-page-turn still work).
    let showsPageTurnButtons: Bool
    /// Transpose offset in semitones. Only used to invalidate the layout cache via `TaskKey` — the score passed in is
    /// already transposed. Without this the `TaskKey.scoreSignature` hash doesn't change on transpose and the layout
    /// task never re-runs.
    let transposeSemitones: Int
    @Bindable var viewModel: ReaderViewModel
    /// Note-editing seam, mirroring `VerticalScoreContainer`: while editing, taps select instead of seeking, the
    /// rebuilt document is published to the host, and `editGeneration` joins the layout task's identity. Page turns
    /// (swipe + tap zones) are unaffected — the editing overlay never takes touches.
    var editingHost: ReaderEditingHost?

    @State var document: LayoutDocument?
    @State var pages: [Range<Int>] = []
    /// `pageIndex` lives on an `@Observable` so `withAnimation` transactions reach the `ScoreScrollHost`-hosted subtree
    /// via the observation system. `UIHostingController` does not forward animation transactions through `rootView`
    /// reassignment — same hazard documented on `PinchState`.
    @State var pageState = PageState()
    @State var liveScrollOffset: CGPoint = .zero
    @State var pinchSession: PinchSession?
    @State var pendingScroll: ScoreScrollCommand?
    @State var contentInsetTop: CGFloat = 0
    @State var lastManualCursor: ScoreCursor?
    @State var pinch = PinchState()
    @State var committedZoom: CGFloat = 1.0
    /// `playbackCursor` captured at swipe start so the end-of-swipe `followCursor` only fires when playback actually
    /// advanced through pages — otherwise a paused-but-visible cursor on a different page would yank the user back.
    @State var swipeStartCursor: ScoreCursor?
    /// The annotation model for the CURRENT page, projected to band space. Reseeded on page/document/model change;
    /// kept equal to the live ink while drawing so the canvas seed never round-trips an in-progress stroke.
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

    /// iPhone gutter applied to the score content inside the page band. On iPad `ReaderScoreLayout` widens this so the
    /// score's edge notes clear the narrowed page-turn tap zones — see `horizontalContentPadding(viewportWidth:)`.
    /// The layout uses the gutter-deducted width so the score wraps to its visible width; the page background and tap
    /// zones still span the full band.
    static let phoneContentPadding: CGFloat = 12

    /// Per-viewport horizontal gutter: `phoneContentPadding` on iPhone, a tap-zone-clearing margin on iPad.
    static func horizontalContentPadding(viewportWidth: CGFloat) -> CGFloat {
        ReaderScoreLayout.scoreHorizontalInset(
            viewportWidth: viewportWidth, phoneDefault: phoneContentPadding,
        )
    }

    var body: some View {
        // Outer `GeometryReader` honors parent's `safeAreaPadding(.top, ReaderTopOverlay.height)` and system insets,
        // so `proxy.size` is the visible page band at zoom 1. The scroll host itself is full-bleed; the hosted surface
        // pads by `pageInsets` so it lands inside this same rect — pinch zoom can then expand past the safe area.
        GeometryReader { proxy in
            let viewportWidth = max(proxy.size.width, staffSize * 4)
            let viewportHeight = proxy.size.height
            let viewport = CGSize(width: viewportWidth, height: viewportHeight)
            let contentPadding = Self.horizontalContentPadding(viewportWidth: viewportWidth)
            let contentWidth = max(
                viewportWidth - contentPadding * 2,
                staffSize * 4,
            )
            scrollContent(viewport: viewport)
                // Mirror the live viewport so the out-of-body page-turn commits can reseed the annotation canvas
                // synchronously. `initial: true` seeds the first layout; it then tracks rotation / resize.
                    .onChange(of: viewport, initial: true) { _, newValue in lastViewport = newValue }
                    .task(id: TaskKey(
                        score: score, size: staffSize, width: contentWidth,
                        honorLayoutBreaks: honorLayoutBreaks,
                        collapseMultiMeasureRests: collapseMultiMeasureRests,
                        showInvisibleElements: showInvisibleElements,
                        pageHeight: viewportHeight,
                        transposeSemitones: transposeSemitones,
                        editGeneration: editingHost?.editGeneration ?? 0,
                    )) {
                        await rebuildLayout(
                            width: contentWidth,
                            pageHeight: viewportHeight,
                        )
                    }
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
        // Observe live magnification (commit-ease frames re-sync the annotation canvas — see PinchState) and the
        // annotation model (a change reassigns the hosted surface's rootView so static ink layers never go stale).
        _ = pinch.magnification
        _ = viewModel.annotationDrawings
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
            PagedZoomedSurface(
                viewModel: viewModel,
                pinch: pinch,
                pageState: pageState,
                document: document,
                score: score,
                viewport: viewport,
                pageInsets: pageInsets,
                horizontalContentPadding: Self.horizontalContentPadding(viewportWidth: viewport.width),
                scoreOptions: scoreOptions,
                playbackCursor: playbackCursor,
                lastManualCursor: $lastManualCursor,
                pages: pages,
                onPrevPage: { goToPage(delta: -1) },
                onNextPage: { goToPage(delta: +1) },
                onFirstPage: { goToFirstPage() },
                onLastPage: { goToLastPage() },
                onSwipeChanged: { translationX in
                    onSwipeChanged(translationX: translationX, viewportWidth: viewport.width)
                },
                onSwipeEnded: { translationX, predictedEndX, velocityX in
                    onSwipeEnded(
                        translationX: translationX,
                        predictedEndX: predictedEndX,
                        velocityX: velocityX,
                        viewportWidth: viewport.width,
                    )
                },
                // Suppress the onboarding hint while annotating so the dashed preview doesn't sit over the drawing
                // surface; it returns (if not permanently dismissed) once drawing stops.
                showsHint: !pageTapHintDismissed && !viewModel.isAnnotating,
                onAnyZoneTouchDown: { pageTapHintDismissed = true },
                showsTapZones: showsPageTurnButtons,
                editingHost: editingHost,
            )
        }
        // Full-bleed so pinch zoom can stretch the page band beyond the safe area; the hosted surface re-applies
        // `pageInsets` as padding so the band sits inside the safe area at zoom 1.
        .ignoresSafeArea()
        .onChange(of: [playbackCursor, pageAnchorCursor]) { old, new in
            guard readerShouldFollowPlayback(
                autoFollowEnabled: autoFollowEnabled,
                isPlaybackDriven: pageAnchorCursor != nil,
                cursorMoved: old[0] != new[0],
                followSuspended: viewModel.playbackSession.isPlaybackFollowSuspended,
            ) else { return }
            followCursor(pageAnchorCursor ?? playbackCursor)
        }
        .onChange(of: pageState.pageIndex) { _, _ in reprojectCurrentPage(viewport: viewport) }
        .onChange(of: document) { _, _ in reprojectCurrentPage(viewport: viewport) }
        .onChange(of: viewModel.annotationDrawings) { _, _ in
            // Reseed on read-mode model changes; skip while drawing (the canvas is source of truth).
            if !viewModel.isAnnotating { reprojectCurrentPage(viewport: viewport) }
        }
        // Entering/leaving annotation hands the current page off between its static layer and the live canvas.
        .onChange(of: viewModel.isAnnotating) { _, _ in reprojectCurrentPage(viewport: viewport) }
        .onAppear { reprojectCurrentPage(viewport: viewport) }
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
        // In paged mode both axes ride `pinch.offset` (the full-bleed scroll view has no scrollable extent at zoom 1),
        // so the residual is fully animatable: seed it into the live offset to hold the content at its released
        // position, then ease it to zero so it settles at the edge-aligned rest instead of snapping there. Content
        // area = page band + safe-area insets, scaled by the committed zoom; the scroll host is full-bleed so its
        // bounds equal that same padded band at zoom 1. Compute the size explicitly (not via the `expectedContentSize`
        // closure, which reads `committedZoom` — the value we are about to mutate).
        let paddedBounds = CGSize(
            width: viewport.width + pageInsets.leading + pageInsets.trailing,
            height: viewport.height + pageInsets.top + pageInsets.bottom,
        )
        let contentSize = CGSize(width: paddedBounds.width * r.targetZoom, height: paddedBounds.height * r.targetZoom)
        let (clamped, residual) = ReaderPinchCommit.clampScrollTarget(
            r.rawScrollTarget, contentSize: contentSize, bounds: paddedBounds, inset: .zero,
        )

        if r.isBounceBack {
            // Ease frame-by-frame so the ink overlay follows the rubber-band release in lockstep (PinchState).
            pinch.animateReset(toMagnification: 1.0, offsetX: 0, offsetY: 0)
        } else {
            committedZoom = r.targetZoom
            pendingScroll = .immediate(clamped)
            if r.snapToUnit {
                viewModel.resetZoom()
                pinch.magnification = r.compensatedMag
                // Hold at release (seed the residual) then co-ease magnification and offset on one CADisplayLink so
                // scale and position settle together. For snap the range collapses to the origin, so the residual is
                // `-rawScrollTarget` — which also absorbs the live pan the raw target subtracted.
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

    private func currentPageBand(viewport: CGSize) -> (startY: CGFloat, endY: CGFloat, contentPadding: CGFloat)? {
        guard let doc = document, pages.indices.contains(pageState.pageIndex) else { return nil }
        return (
            PagedPageGeometry.pageStartY(forPage: pageState.pageIndex, pages: pages, doc: doc),
            PagedPageGeometry.pageEndY(forPage: pageState.pageIndex, pages: pages, doc: doc),
            Self.horizontalContentPadding(viewportWidth: viewport.width),
        )
    }

    private func annotationSpec(viewport: CGSize) -> AnnotationOverlaySpec {
        AnnotationOverlaySpec(
            isAnnotating: viewModel.isAnnotating,
            isPencilPreferred: UIDevice.current.userInterfaceIdiom == .pad,
            displayDrawing: projectedAnnotations,
            onChange: { drawing in
                // Capture ONLY while annotating: leaving annotation empties the live canvas, and that programmatic
                // `canvas.drawing = empty` fires didChange — recapturing it would wipe this page's committed anchors.
                guard viewModel.isAnnotating, let doc = document, let band = currentPageBand(viewport: viewport) else {
                    return
                }
                projectedAnnotations = drawing // canvas is source of truth this page
                // Re-capture THIS page's strokes; keep every other page's anchors verbatim.
                let (_, offPage) = AnnotationAnchoring.partitionByPage(
                    viewModel.annotationDrawings, in: doc, pageStartY: band.startY, pageEndY: band.endY,
                )
                let captured = AnnotationAnchoring.capturePaged(
                    strokes: drawing.strokes, in: doc, pageStartY: band.startY, contentPadding: band.contentPadding,
                )
                viewModel.annotationDrawingsDidChange(offPage + captured)
            },
            state: { annotationCanvasState(viewport: viewport) },
            handle: annotationHandle,
        )
    }

    /// Mirror the current page band onto the viewport-pinned live canvas (band = viewport, offset by `pageInsets`,
    /// scaled by `viewportZoom × magnification`). Paged carries live pan on both `pinch.offsetX` and `pinch.offsetY`.
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

    /// Not `private`: reactive reseed points (pageIndex / document / isAnnotating / model change) call this.
    func reprojectCurrentPage(viewport: CGSize) {
        projectedAnnotations = projectedDrawing(viewport: viewport)
    }

    /// The current page's annotation model projected to band space, or an empty drawing when not annotating / no
    /// resolvable band (which force-clears the live canvas — see `reseedLiveCanvasForPageTurn`).
    private func projectedDrawing(viewport: CGSize) -> PKDrawing {
        guard viewModel.isAnnotating, let doc = document, let band = currentPageBand(viewport: viewport) else {
            return PKDrawing()
        }
        return AnnotationAnchoring.displayPaged(
            viewModel.annotationDrawings, in: doc,
            pageStartY: band.startY, pageEndY: band.endY, contentPadding: band.contentPadding,
        )
    }

    /// Reseed the viewport-pinned live canvas to the current page synchronously at a page-turn commit. Unlike the
    /// reactive `reprojectCurrentPage` (which only sets `projectedAnnotations` and relies on the next render + the
    /// canvas's byte-identity guard — a race a stale echo can defeat), this drives the canvas imperatively via the
    /// handle so the reseed and its echo-suppression are armed in the commit callout, before any queued echo runs.
    /// An empty projection here force-clears any pre-existing stranded ink.
    func reseedLiveCanvasForPageTurn(viewport: CGSize) {
        let drawing = projectedDrawing(viewport: viewport)
        projectedAnnotations = drawing
        annotationHandle.reseedForPageTurn(drawing)
    }

    var scoreOptions: ScoreViewOptions {
        ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: true, includeTitleFrame: true,
            breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll,
            breakIndicatorVisibility: .none,
            multiMeasureRest: collapseMultiMeasureRests
                ? .collapse(minimumMeasures: ReaderPreferences.multiMeasureRestThreshold)
                : .disabled,
            showsInvisibleElements: showInvisibleElements,
        )
    }

    private func rebuildLayout(width: CGFloat, pageHeight: CGFloat) async {
        let score = score
        let options = scoreOptions
        let policy: LayoutBreakPolicy = honorLayoutBreaks ? .honor : .ignoreAll
        let newDoc = await Task.detached(priority: .userInitiated) {
            LayoutEngine.layout(
                score: score, options: options, availableWidth: width,
            )
        }.value
        guard !Task.isCancelled else { return }
        let newPages = LayoutPaginator.paginate(
            systems: newDoc.systems,
            pageHeight: pageHeight,
            policy: policy,
        )
        document = newDoc
        editingHost?.document = newDoc
        pages = newPages
        if pageState.pageIndex >= newPages.count {
            pageState.pageIndex = max(0, newPages.count - 1)
        }
    }

    private struct TaskKey: Hashable {
        let scoreSignature: Int
        let size: CGFloat
        let width: CGFloat
        let honorLayoutBreaks: Bool
        let collapseMultiMeasureRests: Bool
        let showInvisibleElements: Bool
        let pageHeight: CGFloat
        let transposeSemitones: Int
        let editGeneration: Int

        init(
            score: Score,
            size: CGFloat,
            width: CGFloat,
            honorLayoutBreaks: Bool,
            collapseMultiMeasureRests: Bool,
            showInvisibleElements: Bool,
            pageHeight: CGFloat,
            transposeSemitones: Int,
            editGeneration: Int,
        ) {
            self.editGeneration = editGeneration
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
                ^ score.openingClefSignature
                ^ (transposeSemitones << 24)
            self.size = size
            self.width = width
            self.honorLayoutBreaks = honorLayoutBreaks
            self.collapseMultiMeasureRests = collapseMultiMeasureRests
            self.showInvisibleElements = showInvisibleElements
            self.pageHeight = pageHeight
            self.transposeSemitones = transposeSemitones
        }
    }
}
