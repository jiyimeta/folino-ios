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

/// Vertical playback follow that pins the playing cursor's *system* to the top of the viewport, re-scrolling
/// only when that system or the lookahead region has left the viewport — so between scrolls the cursor drifts
/// downward through the visible area instead of being continuously re-centered.
///
/// `systemMin`/`systemMax` is the playing cursor's system span; `lookaheadMax` is the bottom of the lookahead
/// (a few beats ahead) cursor's system. `topInset` is where the pinned system top is placed below the viewport's
/// top (matching the first system's clearance below the nav chrome). Returns `current` unchanged when the playing
/// system is fully visible AND the lookahead bottom is within the viewport. Otherwise pins the playing system's
/// top to `topInset` below the viewport top: `max(0, systemMin - topInset)`.
///
/// Behavior this produces (one implementation, shared by iOS and Android — parity):
/// - Short systems: the lookahead reaching the bottom snaps the playing system to the top; the cursor then drifts
///   through several fully-visible systems with no further scroll until the lookahead reaches the bottom again.
/// - Tall systems (only ~1 system fits below the pinned one): the lookahead snaps the playing system to the top,
///   then the next snap waits until the playing cursor's own system leaves the viewport bottom.
/// Clamped at `0` on the leading edge; callers clamp the trailing content extent.
public func scrollOffsetPinningSystemTop(
    current: Double,
    systemMin: Double,
    systemMax: Double,
    lookaheadMax: Double,
    viewport: Double,
    topInset: Double,
) -> Double {
    let viewTop = current
    let viewBottom = current + viewport
    let systemFullyVisible = systemMin >= viewTop && systemMax <= viewBottom
    let lookaheadVisible = lookaheadMax <= viewBottom
    if systemFullyVisible, lookaheadVisible {
        return current
    }
    return max(0, systemMin - topInset)
}

/// Whether the Reader should run its playback-cursor follow (auto-scroll in vertical/horizontal, auto-page-turn in
/// page mode) for the current cursor change. `autoFollowEnabled` is the user's opt-out toggle; `isPlaybackDriven` is
/// true when the change comes from continuous playback — i.e. the lookahead anchor cursor is non-nil — rather than a
/// manual seek / scrub / measure-step.
///
/// When the toggle is on, always follow. When off, follow only manual navigation (`!isPlaybackDriven`) so a tap-seek,
/// measure-step, or scrub still brings the target on screen while continuous playback no longer scrolls or turns the
/// page. Shared by iOS and the Android Reader (parity: one implementation).
public func readerShouldFollowPlayback(autoFollowEnabled: Bool, isPlaybackDriven: Bool) -> Bool {
    autoFollowEnabled || !isPlaybackDriven
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
