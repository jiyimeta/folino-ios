import Domain
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Score-specific adapter over `PagedReaderSurface`. Owns the score-rendering inputs (`document`, `score`,
/// `scoreOptions`, `pages`, cursors, `horizontalContentPadding`) and delegates all page-band machinery (transitions,
/// swipe, tap zones, pinch composition) to the generic surface via a `pageContent` closure.
///
/// The public interface is unchanged from before the genericization so `PagedScoreContainer` requires no edits.
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
    /// Horizontal gutter between the page band edge and the score content (wider on iPad so edge notes clear the tap
    /// zones). Supplied by `PagedScoreContainer` so the layout width, the page padding, and the inner clip frame all
    /// agree on one value.
    let horizontalContentPadding: CGFloat
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
        PagedReaderSurface(
            viewModel: viewModel,
            pinch: pinch,
            pageState: pageState,
            viewport: viewport,
            pageInsets: pageInsets,
            pageCount: pages.count,
            onPrevPage: onPrevPage,
            onNextPage: onNextPage,
            onFirstPage: onFirstPage,
            onLastPage: onLastPage,
            onSwipeChanged: onSwipeChanged,
            onSwipeEnded: onSwipeEnded,
            showsHint: showsHint,
            onAnyZoneTouchDown: onAnyZoneTouchDown,
            pageContent: { idx in scorePage(forPage: idx) },
        )
    }

    /// Per-page score content injected into `PagedReaderSurface`. Guards `document` and the index range — returns
    /// `Color.clear` when the layout is not yet available or `idx` is out of range.
    @ViewBuilder
    private func scorePage(forPage idx: Int) -> some View {
        if let doc = document, pages.indices.contains(idx) {
            pageContent(forPage: idx, doc: doc)
        } else {
            Color.clear
        }
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
        .padding(.horizontal, horizontalContentPadding)
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
            width: viewport.width - horizontalContentPadding * 2,
            height: pageHeight,
            alignment: .topLeading,
        )
        .clipped()
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
                viewModel.playbackSession.setManualCursor(cursor)
                lastManualCursor = cursor
            }
    }

    fileprivate static func pageStartY(
        forPage index: Int,
        pages: [Range<Int>],
        doc: LayoutDocument,
    ) -> CGFloat {
        PagedPageGeometry.pageStartY(forPage: index, pages: pages, doc: doc)
    }
}
