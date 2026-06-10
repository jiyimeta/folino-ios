import CoreGraphics
import SheetMusicCore

/// Visibility test for an anchor frame in a scroll view's named coord space. Treats the anchor as visible only when
/// fully inside the viewport — any partial overhang triggers a scroll. The exception: when the anchor is wider than the
/// viewport (nothing we can do), fall back to "any overlap" so the auto-scroll heuristic doesn't oscillate between
/// leading and trailing alignment on every cursor step.
///
/// Used by the PiP frame renderer; the in-app reader containers do their own contentOffset-based visibility math.
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
