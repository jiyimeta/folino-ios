import Domain
import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// Result of evaluating a page-swipe gesture release. `commit*` cases advance / retreat by one page; `cancel`
/// snaps `dragTranslationX` back to 0 without changing `pageIndex`.
enum PageSwipeOutcome: Equatable {
    case commitPrevious
    case commitNext
    case cancel
}

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

    /// Rubber-band damping for the edge-overshoot case. Asymptotes at half the viewport width so the drag still
    /// reads as "tracking the finger" without ever crossing the commit threshold.
    static func dampedTranslation(
        raw: CGFloat,
        viewportWidth: CGFloat,
    ) -> CGFloat {
        guard viewportWidth > 0 else { return 0 }
        let magnitude = abs(raw)
        let damped = viewportWidth * (1 - 1 / (1 + magnitude / viewportWidth))
        return raw < 0 ? -damped : damped
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
                withAnimation(Self.cancelAnimation(
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
            ? Self.dampedTranslation(raw: translationX, viewportWidth: viewportWidth)
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
        let outcome = Self.outcome(
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
            withAnimation(Self.cancelAnimation(
                snapBackDistance: pageState.dragTranslationX,
                viewportWidth: viewportWidth,
            )) {
                pageState.dragTranslationX = 0
            }
        }

        if cursorAdvancedDuringSwipe {
            followCursor(playbackCursor)
        }
    }

    /// Drag-commit variant of `commitPageTurn`. Mutates `pageIndex` and `dragTranslationX` inside the same
    /// `withAnimation` block so every page interpolates from "old baseline + drag" to "new baseline + 0" as one
    /// motion. No freeze-first-page handling — drag commits are always ±1.
    private func commitDragTurn(to target: Int, velocityX: CGFloat, viewportWidth: CGFloat) {
        guard target >= 0, target < pages.count else {
            withAnimation(Self.cancelAnimation(
                snapBackDistance: pageState.dragTranslationX,
                viewportWidth: viewportWidth,
            )) {
                pageState.dragTranslationX = 0
            }
            return
        }
        let remaining = max(0, viewportWidth - abs(pageState.dragTranslationX))
        let animation = Self.commitAnimation(
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

// MARK: - Animation curves & outcome decision

extension PagedScoreContainer {
    /// Cap on the commit animation duration. Matches the original fixed `pageTransitionAnimation` length so a slow
    /// release feels identical to the tap-based page turn — the user only sees a faster transition when they
    /// actually flicked the page.
    static let commitMaxDuration = 0.22
    /// Floor on the commit animation duration. Prevents an aggressive flick from completing so quickly that the
    /// motion is hard to follow.
    static let commitMinDuration = 0.10
    /// Cap on the cancel animation duration. Matches the original snap-back length so a near-threshold cancel
    /// (large `dragTranslationX`) still settles in the familiar time.
    static let cancelMaxDuration = 0.18
    /// Floor on the cancel animation duration. A 50 pt snap-back at the proportional rate would otherwise be
    /// nearly invisible.
    static let cancelMinDuration = 0.08

    /// Commit animation whose duration matches the release velocity. The baseline speed (`viewportWidth /
    /// commitMaxDuration`) acts as a floor on velocity, so slow releases use the tap-based page-turn speed;
    /// flick releases use their own (higher) speed, clamped between `commitMinDuration` and `commitMaxDuration`.
    static func commitAnimation(
        remainingDistance: CGFloat,
        velocityMagnitude: CGFloat,
        viewportWidth: CGFloat,
    ) -> Animation {
        guard viewportWidth > 0, remainingDistance > 0 else {
            return .easeOut(duration: commitMaxDuration)
        }
        let baselineSpeed = Double(viewportWidth) / commitMaxDuration
        let speed = max(Double(velocityMagnitude), baselineSpeed)
        let raw = Double(remainingDistance) / speed
        let duration = min(commitMaxDuration, max(commitMinDuration, raw))
        return .easeOut(duration: duration)
    }

    /// Cancel animation whose duration scales with the snap-back distance. Pure distance-proportional with floor and
    /// ceiling — velocity is not folded in because a cancel almost always means "the user backed off".
    static func cancelAnimation(
        snapBackDistance: CGFloat,
        viewportWidth: CGFloat,
    ) -> Animation {
        guard viewportWidth > 0 else {
            return .smooth(duration: cancelMaxDuration)
        }
        let progress = min(max(Double(abs(snapBackDistance)) / Double(viewportWidth), 0), 1)
        let raw = progress * cancelMaxDuration
        let duration = min(cancelMaxDuration, max(cancelMinDuration, raw))
        return .smooth(duration: duration)
    }

    /// Pure decision: given a drag's final translation, the `predictedEndTranslation.width` fling-projection, the
    /// page-band viewport width, and whether the current page is at either extreme, decide whether the drag should
    /// commit a page turn or snap back.
    ///
    /// Rules:
    /// - At first / last page, drags that would commit "off the edge" cancel regardless of distance (the rubber-band
    ///   damping in the view never lets the visual travel cross the commit threshold, but this is the source of truth).
    /// - Otherwise commit when either the static progress or the predicted-end progress exceeds 30 % of viewport
    ///   width in the same direction. The 30 % threshold matches Apple's "page" feel; the predicted-end branch is the
    ///   fling path that lets a fast, short drag still flip the page.
    static func outcome(
        translationX: CGFloat,
        predictedEndX: CGFloat,
        viewportWidth: CGFloat,
        isAtFirstPage: Bool,
        isAtLastPage: Bool,
    ) -> PageSwipeOutcome {
        guard viewportWidth > 0 else { return .cancel }
        if translationX > 0, isAtFirstPage { return .cancel }
        if translationX < 0, isAtLastPage { return .cancel }

        let threshold: CGFloat = 0.3
        let progress = translationX / viewportWidth
        let predictedProgress = predictedEndX / viewportWidth

        if progress > threshold || predictedProgress > threshold {
            return .commitPrevious
        }
        if progress < -threshold || predictedProgress < -threshold {
            return .commitNext
        }
        return .cancel
    }
}
