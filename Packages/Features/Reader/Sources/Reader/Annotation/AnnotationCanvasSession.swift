import Foundation
import Observation

/// What the live annotation canvas can tell the strip about the session in progress: whether there is anything to
/// undo or redo, and whether the session has changed the ink at all — plus the undo manager itself, which outlives
/// the session. Owned by `ReaderViewModel`, written by `AnnotationCanvasController` (which holds the
/// `PKCanvasView`), read by the strip's controls.
///
/// A class rather than values on the view model because the writer is UIKit code that lives inside the score
/// container's coordinator, not the view model — a stable reference handed down through `AnnotationOverlaySpec` is
/// what lets it report back without the container re-rendering on every stroke.
///
/// **The undo history is PencilKit's, kept alive by not disturbing it.** Undo has to survive leaving annotation mode
/// and coming back — the way the note-editing session's does, and the way Preview's does on iPad — and it has to be
/// the SAME history the palette's own buttons and a three-finger swipe work on. PencilKit registers its undo on the
/// responder chain's `UndoManager` and the canvas honours an `undoManager` override (measured:
/// `PencilKitUndoProbeTests`), so the canvas takes `undoManager` from here and it lives as long as the score is open.
///
/// What PencilKit's undo actions cannot survive is the drawing being **replaced** under them: the manager keeps the
/// group, so the button looks live, but undoing it restores nothing and leaves the stack empty. That is exactly what
/// the paged readers used to do on every exit (emptying the live canvas so the static ink layers could take over).
/// So the canvas is now HIDDEN while idle instead of emptied, no programmatic set happens across a session boundary
/// at all, and any set that does happen (a page turn, a reflow, a re-seed from the store) ends the history
/// (`clearHistory`) rather than leaving a button that does nothing.
///
/// **`hasChanges` is decided at the canvas, not by comparing anchors.** Every capture re-anchors the whole canvas and
/// mints fresh stroke IDs, so "does the model differ from where the session started?" has no reliable answer on the
/// model side. The canvas side does: the controller remembers the drawing bytes it seeded the session with, and
/// compares against them after every change — undoing back to the seed restores the same value and reads as
/// "unchanged" again. (Two `dataRepresentation()` calls on one drawing agree byte for byte; it is only a round trip
/// through `PKDrawing(data:)` that respells it, which is why nothing here stores drawings as snapshots.)
@MainActor
@Observable
final class AnnotationCanvasSession {
    var canUndo = false
    var canRedo = false
    /// Whether this session has put ink down or taken it away, on this page or an earlier one.
    var hasChanges = false

    /// The manager PencilKit registers its strokes on — see the type's doc comment. Not observed: the strip reads
    /// `canUndo` / `canRedo`, which the controller republishes from it.
    @ObservationIgnored let undoManager = UndoManager()

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

    /// Back to a fresh session: nothing changed. The history is deliberately NOT touched — it is what carries undo
    /// across sessions; `clearHistory` ends it.
    func reset() {
        hasChanges = false
    }

    /// End the undo history. For every moment the ink on screen stops being what its actions would restore: the
    /// canvas's drawing being replaced (a page turn, a reflow, a re-seed from the store), ✕, and clear-all.
    func clearHistory() {
        undoManager.removeAllActions()
        canUndo = false
        canRedo = false
    }
}
