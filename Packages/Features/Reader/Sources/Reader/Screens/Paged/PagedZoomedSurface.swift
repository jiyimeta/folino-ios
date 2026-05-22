import Domain
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Reads `pageState.dragTranslationX` in isolation and applies it as a horizontal `.offset` on `content`. This is the
/// only place that touches `dragTranslationX` during rendering — moving the read out of `PagedZoomedSurface.body`
/// stops the whole surface from re-evaluating on every gesture sample, leaving only this modifier's body to recompute
/// while the finger is moving.
private struct BandDragOffset: ViewModifier {
    let pageState: PageState

    func body(content: Content) -> some View {
        content.offset(x: pageState.dragTranslationX)
    }
}

struct PagedZoomedSurface: View {
    @Bindable var viewModel: ReaderViewModel
    @Bindable var pinch: PinchState
    /// Observed directly so the parent's `withAnimation` on `pageIndex` reaches this subtree via observation — the
    /// `UIHostingController` boundary swallows animation transactions delivered through `rootView` reassignment, which
    /// would make the turn snap if we passed `pageIndex` by parameter.
    @Bindable var pageState: PageState
    let document: LayoutDocument?
    let score: Score
    let viewport: CGSize
    let pageInsets: EdgeInsets
    let scoreOptions: ScoreViewOptions
    let playbackCursor: ScoreCursor?
    @Binding var lastManualCursor: ScoreCursor?
    let pages: [Range<Int>]
    let onPrevPage: () -> Void
    let onNextPage: () -> Void
    let onFirstPage: () -> Void
    let onLastPage: () -> Void
    let onSwipeChanged: (CGFloat) -> Void
    /// `(translationX, predictedEndX, velocityX)` — finger lift values forwarded to the container's `onSwipeEnded`.
    /// `velocityX` is `DragGesture.Value.velocity.width` (pt/s) at release.
    let onSwipeEnded: (CGFloat, CGFloat, CGFloat) -> Void
    let showsHint: Bool
    let onAnyZoneTouchDown: () -> Void

    var body: some View {
        if let doc = document, !pages.isEmpty {
            let zoom = viewModel.viewportZoom
            let paddedWidth = viewport.width + pageInsets.leading + pageInsets.trailing
            let paddedHeight = viewport.height + pageInsets.top + pageInsets.bottom
            let framedWidth = paddedWidth * zoom
            let framedHeight = paddedHeight * zoom
            let currentIdx = min(max(pageState.pageIndex, 0), pages.count - 1)
            // Keep both neighbors pre-rendered so a page turn never has to spin up a fresh `ScoreView` at tap time —
            // the pages already exist in the tree, only their offsets animate. Three-way baseline: `idx < currentIdx`
            // sits at `-viewport.width`, `idx == currentIdx` at `0`, `idx > currentIdx` at `+viewport.width`. The live
            // finger translation is applied band-wide one level up so the whole strip slides as one compositing
            // transform rather than `N` per-page offset updates.
            let slideSet = Set([-1, 0, 1].compactMap { delta -> Int? in
                let idx = currentIdx + delta
                return (0 ..< pages.count).contains(idx) ? idx : nil
            })
            // First / last kept resident outside the slide window at `opacity 0` so jump-to-edge taps don't pay the
            // `ScoreView` build cost. They animate via opacity under the same `withAnimation` transaction that drives
            // the slide, which reads as a fade — the only sensible animation when source and target are non-adjacent.
            let edgeSet: Set<Int> = pages.isEmpty
                ? []
                : [0, pages.count - 1]
            let windowIndices = slideSet.union(edgeSet).sorted()

            ZStack(alignment: .topLeading) {
                pageBand(
                    doc: doc,
                    windowIndices: windowIndices,
                    slideSet: slideSet,
                    currentIdx: currentIdx,
                    zoom: zoom,
                )

                // Tap zones extend `pageInsets.leading` / `pageInsets.trailing` outward so the tap-active area reaches
                // the host's edges in landscape, where there is otherwise a safe-area gutter that would swallow edge
                // taps.
                tapOverlay()
                    .padding(.top, pageInsets.top)
                    .padding(.bottom, pageInsets.bottom)
            }
            .scaleEffect(pinch.magnification, anchor: pinch.anchor)
            .scaleEffect(zoom, anchor: .topLeading)
            .offset(x: pinch.offsetX, y: pinch.offsetY)
            .frame(
                width: framedWidth,
                height: framedHeight,
                alignment: .topLeading,
            )
        } else {
            Color.clear
        }
    }

    private func pageBand(
        doc: LayoutDocument,
        windowIndices: [Int],
        slideSet: Set<Int>,
        currentIdx: Int,
        zoom: CGFloat,
    ) -> some View {
        // Page band — clipped to viewport and inset by `pageInsets` so the music sits inside the safe area + overlay
        // reserve. Tap zones live outside this wrapper so they can still reach the host's edges.
        ZStack(alignment: .topLeading) {
            ForEach(windowIndices, id: \.self) { idx in
                let inSlideWindow = slideSet.contains(idx)
                // `freezeFirstPageOffset` overrides idx 0 to hold at `0` during jump-from / jump-to-first transitions
                // so jump-to-first fades in at center instead of sliding rightward from `-viewport.width`.
                let baseOffset: CGFloat = if idx < currentIdx {
                    -viewport.width
                } else if idx == currentIdx {
                    0
                } else {
                    viewport.width
                }
                let frozenFirstPage = idx == 0
                    && pageState.freezeFirstPageOffset
                pageContent(forPage: idx, doc: doc)
                    .offset(x: frozenFirstPage ? 0 : baseOffset)
                    .opacity(inSlideWindow ? 1 : 0)
                    .allowsHitTesting(inSlideWindow)
                    // Subtracting `pages.count` for non-slide entries pushes resident edge pages below every slide
                    // page so the opacity crossfade is hidden beneath whichever slide page covers the same region.
                    .zIndex(
                        inSlideWindow
                            ? -Double(idx)
                            : -Double(idx) - Double(pages.count),
                    )
                    // Removed pages disappear instantly. Inserted pages fade in via opacity so a fresh slide-next
                    // page doesn't pop in at full opacity on top of the still-fading target.
                    .transition(
                        .asymmetric(
                            insertion: .opacity,
                            removal: .identity,
                        ),
                    )
            }
        }
        // Live drag translation applied once for the whole band — every page slides together as a compositing
        // transform. The read of `dragTranslationX` is isolated inside `BandDragOffset` so the enclosing
        // `PagedZoomedSurface.body` does not invalidate on every drag sample.
        .modifier(BandDragOffset(pageState: pageState))
        // Clip neighbors to the page band. Without this, the pre-rendered previous page (offset `-viewport.width`)
        // leaks out the leading side whenever the band does not fully cover the host.
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .clipped()
        .padding(pageInsets)
        // Single band-level swipe gesture (previously per-page → up to 5 concurrent recognizers oscillating
        // `dragTranslationX`, visible as jitter). `minimumDistance: 8` lets a tap below the threshold still reach
        // the per-page `tapSeekGesture`; crossing 8 pt activates the swipe and the tap-seek's `SpatialTapGesture`
        // is rejected on release (high travel).
        //
        // Above unit zoom the swipe is masked off (`.subviews`) so the hosting `UIScrollView`'s pan recogniser
        // can claim the touch and handle one-finger panning of the zoomed score.
        .simultaneousGesture(
            pageSwipeGesture(),
            including: abs(zoom - 1.0) < 0.001 ? .all : .subviews,
        )
    }

    private func pageContent(
        forPage idx: Int,
        doc: LayoutDocument,
    ) -> some View {
        let pageRange = pages[idx]
        let lastSystemIndex = pageRange.upperBound - 1
        // Start the clip from the previous page's last-system bottom (or `0` for the first page) so the gap above the
        // current page's first system — where rehearsal marks sit, plus the title frame on page 0 — renders here.
        let pageStartY = PagedZoomedSurface.pageStartY(
            forPage: idx, pages: pages, doc: doc,
        )
        let pageEndY: CGFloat = (0 ..< doc.systems.count).contains(lastSystemIndex)
            ? doc.systems[lastSystemIndex].origin.y
            + doc.systems[lastSystemIndex].size.height
            : pageStartY
        let pageHeight = max(0, pageEndY - pageStartY)
        // Sub-document containing only this page's systems — each ScoreView would otherwise construct a
        // `SystemLayerView` for every system in the full doc, multiplying layout cost by `windowIndices.count`.
        // `origin.y` is preserved so the existing `.offset(y: -pageStartY)` + outer `.clipped()` machinery still
        // positions the page correctly. `titleFrame` is preserved only on idx 0.
        let pageSystems = Array(doc.systems[pageRange])
        let pageDoc = LayoutDocument(
            size: doc.size,
            systems: pageSystems,
            metrics: doc.metrics,
            titleFrame: idx == 0 ? doc.titleFrame : nil,
        )
        return scoreSurface(
            document: pageDoc,
            pageStartY: pageStartY,
            pageHeight: pageHeight,
        )
        // Inset by the shared horizontal gutter so the page background still spans the full band but the music sits
        // inboard. The layout uses the same gutter-deducted width, so the score wraps to fit inside.
        .padding(.horizontal, PagedScoreContainer.horizontalContentPadding)
            // White fills the full viewport so any unused space beneath the last system reads as part of the page
            // (just like `SheetMusicUI.PagedScoreView`'s canvas) rather than the host scroll background.
            .frame(width: viewport.width, height: viewport.height, alignment: .top)
            .background(Color.white)
    }

    private func scoreSurface(
        document doc: LayoutDocument,
        pageStartY: CGFloat,
        pageHeight: CGFloat,
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ScoreView(
                document: doc, score: score, options: scoreOptions,
                playbackCursor: playbackCursor, playbackCursorColor: .accentColor,
            )
            .coordinateSpace(name: "scoreSurface")
            .gesture(tapSeekGesture(
                document: doc, pageStartY: pageStartY, pageHeight: pageHeight,
            ))
            .sensoryFeedback(.impact(weight: .medium), trigger: lastManualCursor)

            if viewModel.repeatModel.mode == .abLoop {
                LoopRegionOverlay(document: doc, range: viewModel.repeatModel.abRange)
                LoopBoundaryMarkers(
                    document: doc,
                    start: viewModel.repeatModel.pendingRepeatA,
                    end: viewModel.repeatModel.pendingRepeatB,
                )
            }
        }
        .frame(height: doc.size.height, alignment: .topLeading)
        .offset(y: -pageStartY)
        // `.topLeading` (not `.top`) prevents the default `.center` horizontal alignment from drifting the doc when
        // `doc.size.width` ≠ inner width — which would clip part-labels on the leading edge.
        .frame(
            width: viewport.width - PagedScoreContainer.horizontalContentPadding * 2,
            height: pageHeight,
            alignment: .topLeading,
        )
        .clipped()
    }

    private func tapOverlay() -> some View {
        TapOverlay(
            viewport: viewport,
            leadingExtra: pageInsets.leading,
            trailingExtra: pageInsets.trailing,
            onFirstPage: onFirstPage,
            onPrevPage: onPrevPage,
            onLastPage: onLastPage,
            onNextPage: onNextPage,
            currentPageNumber: pageState.pageIndex + 1,
            totalPages: pages.count,
            showsHint: showsHint,
            onAnyZoneTouchDown: onAnyZoneTouchDown,
        )
    }

    private func tapSeekGesture(
        document: LayoutDocument,
        pageStartY: CGFloat,
        pageHeight: CGFloat,
    ) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named("scoreSurface"))
            .onEnded { value in
                // The named coordinate space spans the full doc (the inner `ScoreView` is `doc.size.height` tall and
                // the wrapper offsets it up by `pageStartY`). The outer `.clipped()` clips rendering but not hit
                // testing, so a tap on the blank band beneath the last visible system still resolves to a y on the
                // next page. Without this guard, `nearestCursor` would return the next-page system and the user
                // would perceive the page advancing whenever they tap the lower screen area.
                let pageEndY = pageStartY + pageHeight
                guard value.location.y >= pageStartY,
                      value.location.y <= pageEndY else { return }
                guard let cursor = nearestCursor(at: value.location, in: document) else { return }
                viewModel.setManualCursor(cursor)
                lastManualCursor = cursor
            }
    }

    private func pageSwipeGesture() -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                // Per-sample horizontal-dominance gate: ignore vertical-dominant samples so a future vertical-scroll
                // surface could coexist. Pure-horizontal drags satisfy `abs(dy) == 0`, well below `abs(dx) / 1.5`.
                guard abs(value.translation.width)
                    > abs(value.translation.height) * 1.5
                else { return }
                onSwipeChanged(value.translation.width)
            }
            .onEnded { value in
                onSwipeEnded(
                    value.translation.width,
                    value.predictedEndTranslation.width,
                    value.velocity.width,
                )
            }
    }

    /// First page renders from doc-Y `0` (so the title frame and any pre-system decoration are visible); every
    /// subsequent page starts at the previous page's last-system bottom (so the gap above its own first system —
    /// rehearsal marks, etc. — lands on the right page).
    fileprivate static func pageStartY(
        forPage index: Int,
        pages: [Range<Int>],
        doc: LayoutDocument,
    ) -> CGFloat {
        guard index > 0 else { return 0 }
        let prevLastIndex = pages[index - 1].upperBound - 1
        guard (0 ..< doc.systems.count).contains(prevLastIndex) else { return 0 }
        return doc.systems[prevLastIndex].origin.y
            + doc.systems[prevLastIndex].size.height
    }
}
