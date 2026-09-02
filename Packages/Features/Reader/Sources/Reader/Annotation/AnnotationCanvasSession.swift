import Foundation
import Observation
import ReaderAnnotationCore

/// What the live annotation canvas can tell the strip about the session in progress: whether there is anything to
/// undo or redo, and whether the session has changed the ink at all — plus the undo history itself, which outlives
/// the session. Owned by `ReaderViewModel`, written by `AnnotationCanvasController` (which holds the `PKCanvasView`),
/// read by the strip's controls.
///
/// A class rather than values on the view model because the writer is UIKit code that lives inside the score
/// container's coordinator, not the view model — a stable reference handed down through `AnnotationOverlaySpec` is
/// what lets it report back without the container re-rendering on every stroke.
///
/// **The history lives here, not on the canvas.** Undo has to survive leaving annotation mode and coming back, the
/// way the note-editing session's does, and PencilKit's own undo manager does not survive the reseeds the paged
/// readers perform on every exit and page turn. So the controller keeps `AnnotationPageHistory` snapshots per page
/// (keyed by `AnnotationOverlaySpec.historyKey`) and the strip's undo / redo restore them. The history ends with the
/// score's ink: ✕, clear-all, a part remap and a reflow all drop it (`clearHistory`), because the snapshots describe
/// ink positioned against a layout that no longer exists.
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

    /// The undo history of every page the canvas has shown, keyed by the container's `historyKey` (the page index
    /// in a paged reader, `0` in a continuous one). Kept across sessions; see the type's doc comment for when it
    /// ends. Not observed — the strip reads `canUndo` / `canRedo`, which the controller publishes from it.
    @ObservationIgnored var histories: [Int: AnnotationPageHistory] = [:]

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

    /// Forget every page's history. For the moments the ink on screen stops being what the snapshots describe: a
    /// reflow (the anchors project to different geometry), a part remap, ✕, and clear-all.
    func clearHistory() {
        histories = [:]
        canUndo = false
        canRedo = false
    }
}
