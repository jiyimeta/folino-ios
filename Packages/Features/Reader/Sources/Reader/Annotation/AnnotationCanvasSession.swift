import Observation

/// What the live annotation canvas can tell the strip about the session in progress: whether there is anything to
/// undo or redo, and whether the session has changed the ink at all. Owned by `ReaderViewModel`, written by
/// `AnnotationCanvasController` (which holds the `PKCanvasView` and its undo manager), read by the strip's controls.
///
/// A class rather than values on the view model because the writer is UIKit code that lives inside the score
/// container's coordinator, not the view model — a stable reference handed down through `AnnotationOverlaySpec` is
/// what lets it report back without the container re-rendering on every stroke.
///
/// **`hasChanges` is decided at the canvas, not by comparing anchors.** Every capture re-anchors the whole canvas and
/// mints fresh stroke IDs, and a projection round-trip does not reproduce its input byte for byte — so "does the
/// model differ from where the session started?" has no reliable answer on the model side. The canvas side does: the
/// controller remembers the drawing bytes it seeded the session with (carrying that baseline forward across a
/// programmatic reseed while nothing has changed), and compares against them after every change — which also makes
/// undoing back to the seed read as "unchanged" again, exactly as the editing session's command stack does.
@MainActor
@Observable
final class AnnotationCanvasSession {
    var canUndo = false
    var canRedo = false
    /// Whether this session has put ink down or taken it away, on this page or an earlier one.
    var hasChanges = false

    /// Installed by the canvas controller; `nil` until a canvas exists. The strip's undo / redo buttons are disabled
    /// on `canUndo` / `canRedo`, never on these being present.
    @ObservationIgnored var performUndo: (@MainActor () -> Void)?
    @ObservationIgnored var performRedo: (@MainActor () -> Void)?

    func undo() {
        performUndo?()
    }

    func redo() {
        performRedo?()
    }

    /// Back to a fresh session: nothing to undo, nothing changed.
    func reset() {
        canUndo = false
        canRedo = false
        hasChanges = false
    }
}
