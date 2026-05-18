import SwiftUI

/// Page-turn state shared between `PagedScoreContainer` and
/// `PagedZoomedSurface`.
///
/// Kept as an `@Observable` reference (not individual `@State` on the
/// container) for the same reason as `PinchState`: `ScoreScrollHost`
/// wraps a `UIHostingController`, and animation transactions from an
/// outer `withAnimation { … }` do *not* propagate through the host's
/// `rootView` reassignment — the inner SwiftUI render sees a fresh tree
/// with no transaction. Driving these values through observation makes
/// the hosted subtree re-render inside the animation transaction the
/// mutation was made under, so `slideProgress` interpolates instead of
/// snapping.
///
/// The container owns the instance via `@State`, so the same observable
/// lives for the view's lifetime; only its properties change.
@Observable
@MainActor
final class PageState {
    /// Currently visible page (index into `PagedScoreContainer.pages`).
    /// Updated synchronously at the start of a turn so cursor follow,
    /// layout rebuild, etc. see the new page immediately; the visual
    /// catch-up happens via `slideProgress`.
    var pageIndex = 0
    /// Direction of the turn currently animating, if any. Set
    /// alongside `outgoingIndex` at the start of a turn.
    var pageDirection: PagedScoreContainer.PageDirection = .forward
    /// Index of the page we are turning *away from* during the
    /// transition. `nil` in steady state — only `pageIndex` is
    /// rendered then.
    var outgoingIndex: Int?
    /// Animation progress 0 → 1. Drives the moving page's horizontal
    /// `offset`: on `.forward` it shifts the outgoing page from `0`
    /// to `-width`; on `.backward` it shifts the incoming page from
    /// `-width` to `0`.
    var slideProgress: CGFloat = 0
    /// Identifies the in-flight turn. The animation `completion:`
    /// callback only clears `outgoingIndex` if the token still
    /// matches — protects against a new turn starting before the
    /// previous one's completion fires.
    var transitionToken: UUID?
}
