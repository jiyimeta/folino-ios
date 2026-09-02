import Foundation
import Observation

/// What the live annotation canvas can tell the strip about the session in progress: whether there is anything to
/// undo or redo, and whether the session has changed the ink at all — plus the undo managers themselves, which
/// outlive the session. Owned by `ReaderViewModel`, written by `AnnotationCanvasController` (which holds the
/// `PKCanvasView`), read by the strip's controls.
///
/// A class rather than values on the view model because the writer is UIKit code that lives inside the score
/// container's coordinator, not the view model — a stable reference handed down through `AnnotationOverlaySpec` is
/// what lets it report back without the container re-rendering on every stroke.
///
/// **The undo history is PencilKit's, kept alive by us.** Undo has to survive leaving annotation mode and coming
/// back — the way the note-editing session's does, and the way Preview's does on iPad — and it has to be the SAME
/// history the palette's own buttons and a three-finger swipe work on. PencilKit registers its undo on the
/// responder chain's `UndoManager` (measured: `PencilKitUndoProbeTests`), a programmatic `drawing` set neither
/// clears that manager nor pushes onto it, and the canvas honours an `undoManager` override — so the canvas hands
/// PencilKit one manager per page from `undoManagers`, and the paged readers' exit-time emptying and page-turn
/// reseeds pass through it untouched. Nothing here snapshots drawings: `PKDrawing.dataRepresentation()` is not
/// byte-stable across a round trip, so a snapshot history could not tell an undo from a fresh edit.
///
/// The history ends with the score's ink: ✕, clear-all, a part remap and a reflow all drop it (`clearHistory`),
/// because its actions would restore ink positioned against a layout that no longer exists.
///
/// **`hasChanges` is decided at the canvas, not by comparing anchors.** Every capture re-anchors the whole canvas and
/// mints fresh stroke IDs, so "does the model differ from where the session started?" has no reliable answer on the
/// model side. The canvas side does: the controller remembers the drawing bytes it seeded the session with
/// (carrying that baseline forward across a programmatic reseed while nothing has changed), and compares against
/// them after every change — undoing back to the seed restores the same `PKDrawing` value and reads as "unchanged"
/// again. (Two calls on the same drawing DO agree byte for byte; it is only a round trip that respells it.)
@MainActor
@Observable
final class AnnotationCanvasSession {
    var canUndo = false
    var canRedo = false
    /// Whether this session has put ink down or taken it away, on this page or an earlier one.
    var hasChanges = false

    /// One undo manager per page the canvas has shown, keyed by the container's `historyKey` (the page index in a
    /// paged reader, `0` in a continuous one). Kept across sessions; see the type's doc comment for when they end.
    /// Not observed — the strip reads `canUndo` / `canRedo`, which the controller publishes from the current one.
    @ObservationIgnored private var undoManagers: [Int: UndoManager] = [:]

    /// Installed by the canvas controller; `nil` until a canvas exists. The strip's undo / redo buttons are disabled
    /// on `canUndo` / `canRedo`, never on these being present.
    @ObservationIgnored var performUndo: (@MainActor () -> Void)?
    @ObservationIgnored var performRedo: (@MainActor () -> Void)?

    /// The page's undo manager, created on first sight of the page. Grouping is left to PencilKit, which opens and
    /// closes a group per stroke.
    func undoManager(for key: Int) -> UndoManager {
        if let existing = undoManagers[key] {
            return existing
        }
        let manager = UndoManager()
        undoManagers[key] = manager
        return manager
    }

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

    /// Forget every page's history. For the moments the ink on screen stops being what the history's actions would
    /// restore: a reflow (the anchors project to different geometry), a part remap, ✕, and clear-all. The managers
    /// are emptied rather than dropped so a canvas still holding one keeps pointing at a live, empty manager.
    func clearHistory() {
        for manager in undoManagers.values {
            manager.removeAllActions()
        }
        canUndo = false
        canRedo = false
    }
}
