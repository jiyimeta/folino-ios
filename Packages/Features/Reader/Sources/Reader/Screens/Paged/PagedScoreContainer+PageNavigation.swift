import Domain
import SheetMusicCore
import SheetMusicLayout
import SwiftUI

// MARK: - Page-index navigation (taps / cursor follow)

extension PagedScoreContainer {
    func followCursor(_ cursor: ScoreCursor?) {
        guard !pageState.isDragging else { return }
        guard let cursor, let doc = document else { return }
        let mi = measureIndex(of: cursor)
        guard let sys = systemIndex(forMeasureIndex: mi, in: doc) else { return }
        guard let target = pages.firstIndex(where: { $0.contains(sys) }) else { return }
        guard target != pageState.pageIndex else { return }
        commitPageTurn(to: target)
    }

    private func systemIndex(
        forMeasureIndex mi: Int,
        in doc: LayoutDocument,
    ) -> Int? {
        for (i, sys) in doc.systems.enumerated()
            where sys.measures.contains(where: { $0.measureIndex == mi })
        {
            return i
        }
        return nil
    }

    func goToPage(delta: Int) {
        jumpToPage(at: pageState.pageIndex + delta)
    }

    func goToFirstPage() {
        jumpToPage(at: 0)
    }

    func goToLastPage() {
        jumpToPage(at: pages.count - 1)
    }

    private func jumpToPage(at target: Int) {
        guard target >= 0, target < pages.count else { return }
        guard target != pageState.pageIndex else { return }
        // A tap-zone page turn is a manual viewport change → suspend playback follow while playing so the reader stays
        // on the page they turned to instead of the next cursor tick snapping back to the playhead.
        viewModel.playbackSession.suspendPlaybackFollowForManualViewportChange()
        viewModel.resetZoom()
        committedZoom = 1.0
        pinch.magnification = 1.0
        pinch.anchor = .center
        pinch.offsetX = 0
        pinch.offsetY = 0
        commitPageTurn(to: target)
    }

    /// Drives the page turn by mutating `pageIndex` inside `withAnimation`. `PagedZoomedSurface` keeps adjacent pages
    /// pre-rendered, and every page's `.offset` is a pure function of its index vs the current one — so a single
    /// `pageIndex` change makes the moving side interpolate while the static side stays put.
    ///
    /// Jumps involving idx 0 flip `pageState.freezeFirstPageOffset` so idx 0 stays pinned at `offset 0` for the
    /// duration. Otherwise idx 0 would slide between `-viewport.width` (its always-rule resting position) and `0` (its
    /// current-page slide position), reading as a sideways slide rather than the symmetric fade idx-last gets for free.
    /// The flag is released in `completion:` so the static state can settle back while idx 0 is invisible.
    private func commitPageTurn(to target: Int) {
        let previous = pageState.pageIndex
        let isJump = abs(target - previous) > 1
        let involvesFirstPage = target == 0 || previous == 0
        let shouldFreeze = isJump && involvesFirstPage

        if shouldFreeze {
            pageState.freezeFirstPageOffset = true
        }
        withAnimation(Self.pageTransitionAnimation) {
            pageState.pageIndex = target
        } completion: {
            if shouldFreeze {
                pageState.freezeFirstPageOffset = false
            }
        }
        // Reset scroll position when the previous page was scrolled (zoomed-in panning). Skipping when already at
        // origin avoids a `ScoreScrollHost.updateUIView` pass with a costly `layoutIfNeeded()`.
        if liveScrollOffset != .zero {
            pendingScroll = .immediate(.zero)
        }
    }
}

// MARK: - Swipe gesture

extension PagedScoreContainer {
    /// Page-swipe activation gate: only at unit zoom, with no pinch in flight, on a multi-page document. The 0.001
    /// epsilon guards against floating-point drift.
    var pageSwipeEnabled: Bool {
        abs(viewModel.viewportZoom - 1.0) < 0.001
            && pinchSession == nil
            && pages.count > 1
    }

    /// Live drag → `dragTranslationX`. Applies rubber-band damping on the impossible-commit side. If the gate flips
    /// false mid-gesture (e.g. a second finger landed and started a pinch), treat the drag as cancelled.
    func onSwipeChanged(
        translationX: CGFloat,
        viewportWidth: CGFloat,
    ) {
        guard pageSwipeEnabled else {
            if pageState.isDragging {
                pageState.isDragging = false
                swipeStartCursor = nil
                withAnimation(PagedReaderNavigation.cancelAnimation(
                    snapBackDistance: pageState.dragTranslationX,
                    viewportWidth: viewportWidth,
                )) {
                    pageState.dragTranslationX = 0
                }
            }
            return
        }
        if !pageState.isDragging {
            swipeStartCursor = playbackCursor
        }
        pageState.isDragging = true
        let atFirst = pageState.pageIndex == 0
        let atLast = pageState.pageIndex == pages.count - 1
        let needsDamping = (translationX > 0 && atFirst)
            || (translationX < 0 && atLast)
        pageState.dragTranslationX = needsDamping
            ? PagedReaderNavigation.dampedTranslation(raw: translationX, viewportWidth: viewportWidth)
            : translationX
    }

    /// Drag release → run through `outcome` and dispatch. Commit folds `dragTranslationX` back into the
    /// `commitPageTurn` animation; cancel snaps back with a shorter curve. Either way, `isDragging` clears and —
    /// only when the playback cursor actually advanced during the gesture — `followCursor` re-runs so the page
    /// catches up to active playback. A static cursor leaves the user's swipe destination alone.
    func onSwipeEnded(
        translationX: CGFloat,
        predictedEndX: CGFloat,
        velocityX: CGFloat,
        viewportWidth: CGFloat,
    ) {
        guard pageState.isDragging else { return }
        let atFirst = pageState.pageIndex == 0
        let atLast = pageState.pageIndex == pages.count - 1
        let outcome = PagedReaderNavigation.outcome(
            translationX: translationX,
            predictedEndX: predictedEndX,
            viewportWidth: viewportWidth,
            isAtFirstPage: atFirst,
            isAtLastPage: atLast,
        )

        pageState.isDragging = false
        let cursorAdvancedDuringSwipe = playbackCursor != swipeStartCursor
        swipeStartCursor = nil

        switch outcome {
        case .commitNext:
            commitDragTurn(
                to: pageState.pageIndex + 1,
                velocityX: velocityX, viewportWidth: viewportWidth,
            )
        case .commitPrevious:
            commitDragTurn(
                to: pageState.pageIndex - 1,
                velocityX: velocityX, viewportWidth: viewportWidth,
            )
        case .cancel:
            withAnimation(PagedReaderNavigation.cancelAnimation(
                snapBackDistance: pageState.dragTranslationX,
                viewportWidth: viewportWidth,
            )) {
                pageState.dragTranslationX = 0
            }
        }

        // The catch-up only chases active playback; honor the opt-out so a manual swipe is not yanked back. Also skip
        // it once the swipe suspended follow (a committed turn during playback) — the reader chose to leave the
        // playhead's page, so don't chase it back on this same gesture.
        if cursorAdvancedDuringSwipe, autoFollowEnabled, !viewModel.playbackSession.isPlaybackFollowSuspended {
            followCursor(playbackCursor)
        }
    }

    /// Drag-commit variant of `commitPageTurn`. Mutates `pageIndex` and `dragTranslationX` inside the same
    /// `withAnimation` block so every page interpolates from "old baseline + drag" to "new baseline + 0" as one
    /// motion. No freeze-first-page handling — drag commits are always ±1.
    private func commitDragTurn(to target: Int, velocityX: CGFloat, viewportWidth: CGFloat) {
        guard target >= 0, target < pages.count else {
            withAnimation(PagedReaderNavigation.cancelAnimation(
                snapBackDistance: pageState.dragTranslationX,
                viewportWidth: viewportWidth,
            )) {
                pageState.dragTranslationX = 0
            }
            return
        }
        // A committed swipe page-turn is a manual viewport change → suspend playback follow while playing.
        viewModel.playbackSession.suspendPlaybackFollowForManualViewportChange()
        let remaining = max(0, viewportWidth - abs(pageState.dragTranslationX))
        let animation = PagedReaderNavigation.commitAnimation(
            remainingDistance: remaining,
            velocityMagnitude: abs(velocityX),
            viewportWidth: viewportWidth,
        )
        withAnimation(animation) {
            pageState.pageIndex = target
            pageState.dragTranslationX = 0
        }
        pendingScroll = .immediate(.zero)
    }
}
