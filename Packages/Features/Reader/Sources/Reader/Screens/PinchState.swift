import CoreGraphics
import SwiftUI

/// Live, gesture-driven pinch state shared by `VerticalScoreContainer` and `HorizontalScoreContainer`.
///
/// Kept as an `@Observable` reference (not individual `@State` on the container) so SwiftUI's observation system
/// delivers mutations straight to the hosted score subtree. That matters because `ScoreScrollHost` is a
/// `UIViewRepresentable` wrapping a `UIHostingController`, and a `withAnimation { … }` at the call site does *not*
/// propagate through the host's `rootView` reassignment — the inner SwiftUI render sees a fresh tree with no
/// transaction. Driving the values through observation instead avoids the bridge entirely: the hosted subtree
/// re-renders inside the animation transaction the mutation was made under, so `scaleEffect` / `offset` / `frame`
/// interpolate as expected.
///
/// The container owns the instance via `@State`, so the same observable lives for the view's lifetime; only its
/// properties change.
@Observable
@MainActor
final class PinchState {
    /// Inner scaleEffect factor, pivoted at `anchor`. Set every `.changed` tick to `UIPinchGestureRecognizer.scale`
    /// (1.0 at gesture start) and reset to 1.0 at commit time.
    var magnification: CGFloat = 1.0
    /// Inner scaleEffect anchor in the hosted content's unit space. Captured once at `.began` so the visual pivot stays
    /// under the user's fingers for the duration of the gesture.
    var anchor: UnitPoint = .center
    /// Horizontal pan-during-pinch offset. Used by `VerticalScoreContainer` (where the UIScrollView has no horizontal
    /// scrollable extent at user-zoom 1.0). Horizontal mode reads this but writes nothing — its X axis pans via the
    /// scroll view's native `contentOffset`.
    var offsetX: CGFloat = 0
    /// Vertical pan-during-pinch offset. Mirror of `offsetX`, used by `HorizontalScoreContainer` (where the
    /// UIScrollView has no vertical scrollable extent at user-zoom 1.0).
    var offsetY: CGFloat = 0
}
