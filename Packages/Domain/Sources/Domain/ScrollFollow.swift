import Foundation

/// Smallest scroll offset that keeps the 1-D interval `[targetMin, targetMax]` inside a viewport of size
/// `viewport` (whose visible range is `[current, current + viewport]`), leaving `pad` margin when a scroll is
/// needed. Returns `current` unchanged when the target is already fully visible — this preserves a manual scroll
/// position while playback advances within the visible region.
///
/// Shared playback-cursor follow logic for the Reader on both iOS and Android (parity: identical behavior, one
/// implementation). All values are in the same coordinate space (e.g. scaled content pixels). The result is
/// clamped at `0` on the leading edge; callers are responsible for clamping against the trailing content extent.
public func scrollOffsetKeepingInView(
    current: Double,
    targetMin: Double,
    targetMax: Double,
    viewport: Double,
    pad: Double,
) -> Double {
    let viewMin = current
    let viewMax = current + viewport
    // Target taller than the viewport: pin its top (with no pad) so as much as possible is shown.
    if targetMax - targetMin > viewport {
        return max(0, targetMin)
    }
    // Already fully visible: don't move (preserves manual scrolling).
    if targetMin >= viewMin, targetMax <= viewMax {
        return current
    }
    // Above the viewport: bring the top in with padding.
    if targetMin < viewMin {
        return max(0, targetMin - pad)
    }
    // Below the viewport: bring the bottom in with padding.
    return targetMax - viewport + pad
}

/// Horizontal auto-scroll offset for measure-anchored stepping. When the
/// cursor's measure `[measureMin, measureMax]` is fully visible in the viewport
/// `[current, current + viewport]`, the offset is unchanged (preserves manual
/// scroll). Otherwise the measure's leading edge is parked at the viewport's
/// left, minus `pad`, clamped at 0. Shared by iOS `HorizontalScoreContainer`
/// and the Android Reader (parity: one implementation). All values share one
/// coordinate space (scaled content pixels).
public func horizontalMeasureScrollOffset(
    current: Double,
    measureMin: Double,
    measureMax: Double,
    viewport: Double,
    pad: Double,
) -> Double {
    let fullyVisible = measureMin >= current && measureMax <= current + viewport
    return fullyVisible ? current : max(0, measureMin - pad)
}
