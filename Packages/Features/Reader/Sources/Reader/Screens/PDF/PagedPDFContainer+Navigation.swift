// PARITY(macos): extends `PagedPDFContainer` — see the marker on that file for what Ⅳ's Mac reading surface needs.

#if os(iOS)
import SwiftUI

// MARK: - Page-index navigation (taps)

extension PagedPDFContainer {
    func goToPage(delta: Int) {
        jumpToPage(at: pageState.pageIndex + delta)
    }

    func goToFirstPage() {
        jumpToPage(at: 0)
    }

    func goToLastPage() {
        jumpToPage(at: document.pageCount - 1)
    }

    private func jumpToPage(at target: Int) {
        guard target >= 0, target < document.pageCount else { return }
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

    /// Drives the page turn by mutating `pageIndex` inside `withAnimation`. `PagedReaderSurface` keeps adjacent pages
    /// pre-rendered, and every page's `.offset` is a pure function of its index vs the current one — so a single
    /// `pageIndex` change makes the moving side interpolate while the static side stays put.
    ///
    /// Jumps involving idx 0 flip `pageState.freezeFirstPageOffset` so idx 0 stays pinned at `offset 0` for the
    /// duration. Otherwise idx 0 would slide between `-viewport.width` (its always-rule resting position) and `0` (its
    /// current-page slide position), reading as a sideways slide rather than the symmetric fade idx-last gets for free.
    /// The flag is released in `completion:` so the static state can settle back while idx 0 is invisible.
    func commitPageTurn(to target: Int) {
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
        // Reseed the viewport-pinned live canvas to the NEW page imperatively, synchronously, and BEFORE any queued
        // PencilKit `didChange` echo of the just-left page can run — see `reseedLiveCanvasForPageTurn`. The canvas is
        // pinned to the viewport (it can't slide with the page) and sits above every page, so if it keeps the previous
        // page's ink it stays painted over the new page after the turn. `pageIndex` is already the target here, so
        // this projects the new page. The reactive `.onChange(of: pageState.pageIndex)` also fires, but not reliably
        // in step with the `withAnimation` turn, and its `applyDrawing` byte guard can't win the echo race — this
        // makes the handoff to the new page's ink immediate and race-proof.
        reseedLiveCanvasForPageTurn(viewport: lastViewport)
    }
}

// MARK: - Swipe gesture

extension PagedPDFContainer {
    /// Page-swipe activation gate: only at unit zoom, with no pinch in flight, on a multi-page document. The 0.001
    /// epsilon guards against floating-point drift.
    var pageSwipeEnabled: Bool {
        abs(viewModel.viewportZoom - 1.0) < 0.001
            && pinchSession == nil
            && document.pageCount > 1
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
                withAnimation(PagedReaderNavigation.cancelAnimation(
                    snapBackDistance: pageState.dragTranslationX,
                    viewportWidth: viewportWidth,
                )) {
                    pageState.dragTranslationX = 0
                }
            }
            return
        }
        pageState.isDragging = true
        let atFirst = pageState.pageIndex == 0
        let atLast = pageState.pageIndex == document.pageCount - 1
        let needsDamping = (translationX > 0 && atFirst)
            || (translationX < 0 && atLast)
        pageState.dragTranslationX = needsDamping
            ? PagedReaderNavigation.dampedTranslation(raw: translationX, viewportWidth: viewportWidth)
            : translationX
    }

    /// Drag release → run through `outcome` and dispatch. Commit folds `dragTranslationX` back into the
    /// `commitPageTurn` animation; cancel snaps back with a shorter curve. Either way, `isDragging` clears.
    func onSwipeEnded(
        translationX: CGFloat,
        predictedEndX: CGFloat,
        velocityX: CGFloat,
        viewportWidth: CGFloat,
    ) {
        guard pageState.isDragging else { return }
        let atFirst = pageState.pageIndex == 0
        let atLast = pageState.pageIndex == document.pageCount - 1
        let outcome = PagedReaderNavigation.outcome(
            translationX: translationX,
            predictedEndX: predictedEndX,
            viewportWidth: viewportWidth,
            isAtFirstPage: atFirst,
            isAtLastPage: atLast,
        )

        pageState.isDragging = false

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
    }

    /// Drag-commit variant of `commitPageTurn`. Mutates `pageIndex` and `dragTranslationX` inside the same
    /// `withAnimation` block so every page interpolates from "old baseline + drag" to "new baseline + 0" as one
    /// motion. No freeze-first-page handling — drag commits are always ±1.
    private func commitDragTurn(to target: Int, velocityX: CGFloat, viewportWidth: CGFloat) {
        guard target >= 0, target < document.pageCount else {
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
        // Reseed the viewport-pinned live canvas to the new page imperatively, synchronously — see `commitPageTurn`.
        reseedLiveCanvasForPageTurn(viewport: lastViewport)
    }
}
#endif
