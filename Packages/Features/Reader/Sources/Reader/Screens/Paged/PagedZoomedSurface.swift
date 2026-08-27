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
    let showsTapZones: Bool
    /// `nil` (or `isEditing == false`) keeps taps on the manual-cursor seek path. While editing, taps route to
    /// `editingHost.onTap` and the caret overlay is drawn on top — same seam the vertical surface uses. Page turns
    /// (swipe + tap zones) keep working, since the overlay never takes touches.
    var editingHost: ReaderEditingHost?

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
            showsTapZones: showsTapZones,
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
        // Start the clip from the previous page's last-system bottom (or `0` for the first page) so the gap above the
        // current page's first system — where rehearsal marks sit, plus the title frame on page 0 — renders here.
        let pageStartY = PagedZoomedSurface.pageStartY(
            forPage: idx, pages: pages, doc: doc,
        )
        let pageEndY = PagedPageGeometry.pageEndY(forPage: idx, pages: pages, doc: doc)
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
            // Above the white page fill, below the engraving: the run-out beneath the last system on a page is still
            // page, and tapping it while editing means "nothing here", same as the margins.
            .background(editingDeselectCatcher(host: editingHost))
            .background(Color.white)
            // Committed ink as a static band-space layer so it slides with the page on a turn (the viewport-pinned live
            // canvas can't follow the slide). Hidden for the page being actively annotated — the live canvas owns it.
            .overlay(alignment: .topLeading) {
                pageInkLayer(forPage: idx, doc: doc, pageStartY: pageStartY, pageEndY: pageEndY)
            }
    }

    @ViewBuilder
    private func pageInkLayer(
        forPage idx: Int, doc: LayoutDocument, pageStartY: CGFloat, pageEndY: CGFloat,
    ) -> some View {
        if !(viewModel.isAnnotating && idx == pageState.pageIndex) {
            StaticInkLayer(drawing: AnnotationAnchoring.displayPaged(
                viewModel.annotationDrawings, in: doc,
                pageStartY: pageStartY, pageEndY: pageEndY, contentPadding: horizontalContentPadding,
                // Stored anchors are in source addressing; `doc` is engraved from the staff-filtered score.
                staffFilter: .current(viewModel: viewModel, editingHost: editingHost),
            ), size: viewport)
        }
    }

    private func scoreSurface(
        document doc: LayoutDocument,
        pageStartY: CGFloat,
        pageHeight: CGFloat,
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ScoreView(
                document: doc, score: score, options: scoreOptions,
                // `displaySelection`, not `selection`: the editor addresses the unfiltered score, this document is
                // laid out from the staff-filtered one. See `ReaderEditingHost.displayItem(for:)`.
                selection: editingHost?.isEditing == true ? (editingHost?.displaySelection ?? .none) : .none,
                voiceColors: ReaderEditingPresentation.voiceColors,
                playbackCursor: playbackCursor, playbackCursorColor: .accentColor.opacity(0.6),
            )
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

            // Over `ScoreView` — see `VerticalZoomedSurface`; the caret blends into the engraving rather than
            // sitting under an opaque white background.
            if let host = editingHost, host.isEditing {
                EditingSelectionOverlay(host: host, score: score, document: doc)
            }
        }
        .coordinateSpace(name: "scoreSurface")
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
                let insidePage = value.location.y >= pageStartY && value.location.y <= pageEndY
                if let host = editingHost, host.isEditing {
                    // Same guard, different answer. The blank band under the last system on this page is still a tap
                    // on THIS page's paper — it means "nothing here", i.e. deselect. Hit-testing it would instead
                    // land on whatever system the next page starts with, silently selecting a note the user can't
                    // see; dropping it outright (what the seek path below does) left the selection stuck with no way
                    // to clear it in page mode.
                    if insidePage {
                        host.onTap(value.location)
                    } else {
                        host.onTapOutsideScore()
                    }
                    return
                }
                guard insidePage else { return }
                guard let cursor = nearestCursor(at: value.location, in: document) else { return }
                viewModel.playbackSession.setManualCursor(cursor)
                lastManualCursor = cursor
                editingHost?.rememberTappedItem(cursor)
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
