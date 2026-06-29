import CoreGraphics
import SwiftUI

/// Result of evaluating a page-swipe gesture release. `commit*` cases advance / retreat by one page; `cancel`
/// snaps `dragTranslationX` back to 0 without changing `pageIndex`.
enum PageSwipeOutcome: Equatable {
    case commitPrevious
    case commitNext
    case cancel
}

/// Content-agnostic page-turn / swipe decisions + animation curves, shared by the score and PDF paged readers.
/// Moved verbatim from `PagedScoreContainer+PageNavigation` so both paged readers agree on the feel.
enum PagedReaderNavigation {
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
}
