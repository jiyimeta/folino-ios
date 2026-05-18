import SwiftUI

/// Page index shared between `PagedScoreContainer` and `PagedZoomedSurface`.
///
/// Kept as an `@Observable` reference (not individual `@State` on the container) for the same reason as `PinchState`:
/// `ScoreScrollHost` wraps a `UIHostingController`, and animation transactions from an outer `withAnimation { … }` do
/// *not* propagate through the host's `rootView` reassignment — the inner SwiftUI render sees a fresh tree with no
/// transaction. Driving the index through observation makes the hosted subtree re-render inside the animation
/// transaction the mutation was made under, so the page `.offset` formulas interpolate instead of snapping.
///
/// The container owns the instance via `@State`, so the same observable lives for the view's lifetime; only its
/// properties change.
@Observable
@MainActor
final class PageState {
    /// Currently visible page (index into `PagedScoreContainer.pages`). Mutate inside `withAnimation` to drive the
    /// stack slide — every pre-rendered neighbor's `.offset` references this index, so the moving side interpolates
    /// while the static side stays put.
    var pageIndex = 0

    /// When `true`, idx 0 holds at `offset 0` regardless of the slide rule. Used during jumps that involve the first
    /// page so idx 0 fades in (jump-to-first) or out (jump-from-first) at the page center instead of sliding leftward —
    /// matching how the last page's transition naturally reads as a fade because idx-last's offset is `0` in every
    /// state.
    var freezeFirstPageOffset = false
}
