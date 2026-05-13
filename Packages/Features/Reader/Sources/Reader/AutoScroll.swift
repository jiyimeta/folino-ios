import CoreGraphics
import SheetMusicCore

extension ScoreCursor {
    /// Measure index this cursor is parked on, regardless of `.item`
    /// vs `.beat` flavour. Used by `RepeatModel`'s A/B toggle logic to
    /// ask "is this loop boundary already on the same measure as the
    /// playback cursor?".
    var measureIndex: Int {
        switch self {
        case let .item(id): id.measureIndex
        case let .beat(mi, _): mi
        }
    }
}

/// Visibility test for an anchor frame in a scroll view's named
/// coord space. Treats the anchor as visible only when fully inside
/// the viewport — any partial overhang triggers a scroll. The
/// exception: when the anchor is wider than the viewport (nothing
/// we can do), fall back to "any overlap" so the auto-scroll
/// heuristic doesn't oscillate between leading and trailing
/// alignment on every cursor step.
///
/// Used by the PiP frame renderer; the in-app reader containers do
/// their own contentOffset-based visibility math.
func isAnchorFullyVisible(
    anchorMin: CGFloat,
    anchorMax: CGFloat,
    anchorSize: CGFloat,
    viewportSize: CGFloat,
) -> Bool {
    if anchorSize > viewportSize {
        return anchorMax > 0 && anchorMin < viewportSize
    }
    return anchorMin >= 0 && anchorMax <= viewportSize
}
