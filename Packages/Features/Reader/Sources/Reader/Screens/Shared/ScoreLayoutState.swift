import Observation
import SheetMusicLayout

/// The engraved document (and, for the paged reader, its page ranges) a score container is currently showing.
///
/// **Observable rather than `@State`, for the same reason `PageState` is.** A container stores its rebuilt
/// `LayoutDocument` from an async relayout; with `@State` that store did not re-run the container's body, so the new
/// engraving sat in memory until some UNRELATED change forced a render. While editing that unrelated change was the
/// next keystroke's selection update — which is why a note written on iPad appeared only when the following note was
/// typed, however long the gap (measured: the relayout finished 350 ms after the edit, and nothing drew for the next
/// three seconds until the user tapped again).
///
/// The reader's score surface lives inside a `UIHostingController` (`ScoreScrollHost`), and updates only cross that
/// boundary when the container's body re-runs and reassigns `rootView`. Observation invalidates on the READ, so
/// storing a new document here re-runs exactly the bodies that read it — the same propagation `PageState` was made
/// observable to get.
///
/// The container owns the instance via `@State`, so one observable lives for the view's lifetime; only its
/// properties change.
@Observable
@MainActor
final class ScoreLayoutState {
    /// The laid-out score, or nil before the first layout lands.
    var document: LayoutDocument?

    /// System-index ranges, one per page. Paged reader only; the scrolling readers leave it empty.
    var pages: [Range<Int>] = []
}
