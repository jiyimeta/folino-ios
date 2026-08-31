// PARITY(macos): device-idiom (iPhone/iPad) tap-zone sizing consumed only by the Reader's iOS-only paged/vertical
//   containers — see the marker on `PagedScoreContainer.swift` for what Ⅳ's Mac reading surface needs instead.

#if os(iOS)
import SwiftUI
import UIKit

/// Device-dependent horizontal layout for the Reader score surfaces.
///
/// On iPad the page-turn tap zones (Page mode) span far more screen than they need to, so a note near the leading /
/// trailing edge of the score falls under a zone and turns the page instead of seeking playback there. Two coupled
/// adjustments fix that, both gated to iPad:
///
/// - `pageTapZoneWidth` narrows each tap column from the iPhone's `12 %` of the viewport to a compact fixed width.
/// - `scoreHorizontalInset` insets the score content by slightly *less* than that width, so the score's leading /
///   trailing edge margin overlaps the tap zone by a touch (no wasted gap). The leftmost noteheads sit inboard of
///   that edge margin, so they stay tap-to-seek. The same inset is applied in Vertical mode (which has no tap zones)
///   purely so both modes present the score at a matching width with margins off the bezel.
///
/// iPhone keeps its original behavior unchanged: a `12 %` tap column, a slim `12 pt` page gutter, and no
/// Vertical-mode inset.
enum ReaderScoreLayout {
    /// True on iPad. The wide-screen tap zones only swallow edge notes on the larger idiom; iPhone's narrow viewport
    /// already keeps the `12 %` columns slim enough.
    static var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// Width of one leading / trailing page-turn tap column, excluding the safe-area gutter the caller adds on top.
    /// iPhone: `12 %` of the viewport. iPad: a compact fixed width, but never wider than the iPhone `12 %` would be
    /// (so a narrow Split View window can't end up with a *bigger* zone than a phone).
    static func pageTapZoneWidth(viewportWidth: CGFloat) -> CGFloat {
        let phone = viewportWidth * phoneTapZoneFraction
        guard isPad else { return phone }
        return min(iPadTapZoneWidth, phone)
    }

    /// Horizontal inset between the score-content edge and the page band / viewport edge. Page mode passes
    /// `phoneDefault: 12` (its existing gutter); Vertical mode passes `phoneDefault: 0` (it had none). On iPad both
    /// modes get the same inset: `pageTapZoneWidth` minus a small overlap, so the score's edge margin laps slightly
    /// over the tap zone instead of leaving a gap. Clamped to `[0, viewportWidth × cap]` for pathological narrow
    /// windows.
    static func scoreHorizontalInset(viewportWidth: CGFloat, phoneDefault: CGFloat) -> CGFloat {
        guard isPad else { return phoneDefault }
        let inset = pageTapZoneWidth(viewportWidth: viewportWidth) - iPadEdgeOverlap
        return min(max(inset, 0), viewportWidth * iPadInsetCap)
    }

    private static let phoneTapZoneFraction: CGFloat = 0.12
    private static let iPadTapZoneWidth: CGFloat = 50
    private static let iPadEdgeOverlap: CGFloat = 8
    private static let iPadInsetCap: CGFloat = 0.18
}
#endif
