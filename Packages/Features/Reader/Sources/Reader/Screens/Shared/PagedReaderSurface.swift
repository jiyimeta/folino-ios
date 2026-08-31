// PARITY(macos): content-agnostic page-band surface shared by `PagedScoreContainer` and `PagedPDFContainer` — see
//   the marker on those files for what Ⅳ's Mac reading surface needs.

#if os(iOS)
import SwiftUI

/// Reads `pageState.dragTranslationX` in isolation and applies it as a horizontal `.offset` on `content`. This is the
/// only place that touches `dragTranslationX` during rendering — moving the read out of `PagedReaderSurface.body`
/// stops the whole surface from re-evaluating on every gesture sample, leaving only this modifier's body to recompute
/// while the finger is moving.
private struct BandDragOffset: ViewModifier {
    let pageState: PageState

    func body(content: Content) -> some View {
        content.offset(x: pageState.dragTranslationX)
    }
}

/// Content-agnostic page-band surface: slide/fade transition, neighbor pre-render window, swipe drag, tap zones, and
/// pinch `scaleEffect` composition. Per-page content is injected via the `pageContent` closure so the PDF and score
/// paged readers can both reuse this machinery without duplicating the gesture / animation code.
///
/// `PagedZoomedSurface` is the score-specific thin adapter that wraps this surface.
struct PagedReaderSurface<Page: View>: View {
    @Bindable var viewModel: ReaderViewModel
    @Bindable var pinch: PinchState
    /// Observed directly so the parent's `withAnimation` on `pageIndex` reaches this subtree via observation — the
    /// `UIHostingController` boundary swallows animation transactions delivered through `rootView` reassignment, which
    /// would make the turn snap if we passed `pageIndex` by parameter.
    @Bindable var pageState: PageState
    let viewport: CGSize
    let pageInsets: EdgeInsets
    let pageCount: Int
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
    /// When false, the page-turn tap-zone overlay is not rendered. Swipe-to-turn (the band gesture) is unaffected.
    let showsTapZones: Bool
    @ViewBuilder let pageContent: (Int) -> Page

    var body: some View {
        if pageCount > 0 {
            let zoom = viewModel.viewportZoom
            let paddedWidth = viewport.width + pageInsets.leading + pageInsets.trailing
            let paddedHeight = viewport.height + pageInsets.top + pageInsets.bottom
            let framedWidth = paddedWidth * zoom
            let framedHeight = paddedHeight * zoom
            let currentIdx = min(max(pageState.pageIndex, 0), pageCount - 1)
            // Keep both neighbors pre-rendered so a page turn never has to spin up a fresh view at tap time —
            // the pages already exist in the tree, only their offsets animate. Three-way baseline: `idx < currentIdx`
            // sits at `-viewport.width`, `idx == currentIdx` at `0`, `idx > currentIdx` at `+viewport.width`. The live
            // finger translation is applied band-wide one level up so the whole strip slides as one compositing
            // transform rather than `N` per-page offset updates.
            let slideSet = Set([-1, 0, 1].compactMap { delta -> Int? in
                let idx = currentIdx + delta
                return (0 ..< pageCount).contains(idx) ? idx : nil
            })
            // First / last kept resident outside the slide window at `opacity 0` so jump-to-edge taps don't pay the
            // view build cost. They animate via opacity under the same `withAnimation` transaction that drives
            // the slide, which reads as a fade — the only sensible animation when source and target are non-adjacent.
            let edgeSet: Set<Int> = pageCount == 0
                ? []
                : [0, pageCount - 1]
            let windowIndices = slideSet.union(edgeSet).sorted()

            ZStack(alignment: .topLeading) {
                pageBand(
                    windowIndices: windowIndices,
                    slideSet: slideSet,
                    currentIdx: currentIdx,
                    zoom: zoom,
                )

                // Tap zones extend `pageInsets.leading` / `pageInsets.trailing` outward so the tap-active area reaches
                // the host's edges in landscape, where there is otherwise a safe-area gutter that would swallow edge
                // taps.
                if showsTapZones {
                    tapOverlay()
                        .padding(.top, pageInsets.top)
                        .padding(.bottom, pageInsets.bottom)
                }
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
                pageContent(idx)
                    .offset(x: frozenFirstPage ? 0 : baseOffset)
                    .opacity(inSlideWindow ? 1 : 0)
                    .allowsHitTesting(inSlideWindow)
                    // Subtracting `pageCount` for non-slide entries pushes resident edge pages below every slide
                    // page so the opacity crossfade is hidden beneath whichever slide page covers the same region.
                    .zIndex(
                        inSlideWindow
                            ? -Double(idx)
                            : -Double(idx) - Double(pageCount),
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
        // `PagedReaderSurface.body` does not invalidate on every drag sample.
        .modifier(BandDragOffset(pageState: pageState))
        // Clip neighbors to the page band. Without this, the pre-rendered previous page (offset `-viewport.width`)
        // leaks out the leading side whenever the band does not fully cover the host.
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .clipped()
        .padding(pageInsets)
        // Single band-level swipe gesture (previously per-page → up to 5 concurrent recognizers oscillating
        // `dragTranslationX`, visible as jitter). `minimumDistance: 8` lets a tap below the threshold still reach
        // the per-page seek gesture; crossing 8 pt activates the swipe and the tap gesture is rejected on release
        // (high travel).
        //
        // Above unit zoom the swipe is masked off (`.subviews`) so the hosting `UIScrollView`'s pan recogniser
        // can claim the touch and handle one-finger panning of the zoomed score.
        .simultaneousGesture(
            pageSwipeGesture(),
            including: abs(zoom - 1.0) < 0.001 ? .all : .subviews,
        )
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
            totalPages: pageCount,
            showsHint: showsHint,
            onAnyZoneTouchDown: onAnyZoneTouchDown,
        )
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
}
#endif
