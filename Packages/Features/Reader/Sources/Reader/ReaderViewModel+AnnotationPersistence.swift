import Domain
import Foundation

// MARK: - Annotation persistence (M2 — per-stroke musical anchoring)

extension ReaderViewModel {
    /// Loads any persisted annotation layer for the current score into `annotationDrawings`. Called from `load()` once
    /// the score and preferences are ready. The shared coordinator owns the decode + miss handling (empty on no layer).
    func loadAnnotations() async {
        annotationDrawings = await annotationCoordinator.load(scoreID: scoreItem.id)
    }

    /// Called by the container on every canvas change with the freshly re-anchored drawings. Updates the in-memory
    /// model immediately (so a re-render projects the live ink, not a stale model) and hands the change to the shared
    /// `AnnotationSaveCoordinator`, which owns the ~0.5 s debounce, the empty→delete policy, and the payload assembly.
    func annotationDrawingsDidChange(_ drawings: [DrawingAnchor]) {
        // A net increase in anchored strokes means new ink was actually committed — the real pencil-usage signal. The
        // canvas's `canvasViewDrawingDidChange` also fires for reflow re-anchoring (same count) and erase (lower
        // count); only a higher count is a fresh commit, so this logs once per committed stroke, never per change tick
        // and never per pixel. Must run before `annotationDrawings` is reassigned below (it is the previous count).
        if drawings.count > annotationDrawings.count {
            recordAnnotationStroke()
        }
        annotationDrawings = drawings
        let scoreID = scoreItem.id
        // The coordinator is an `actor`, so hop off this synchronous @MainActor canvas callback. Keep the task handle
        // so `flushPendingAnnotationSave` can await this registration before flushing — preserving the old guarantee
        // that a score-swap / teardown flush always observes the latest change.
        annotationChangeTask = Task { [annotationCoordinator] in
            await annotationCoordinator.drawingsDidChange(drawings, scoreID: scoreID)
        }
    }

    /// Writes (or deletes) the pending change immediately, bypassing the debounce. Called before `advance` swaps the
    /// score and on VM teardown so no ink is lost mid-transition. Awaits the most recent `drawingsDidChange` hop first
    /// so the flush can't race ahead of an in-flight change registration.
    func flushPendingAnnotationSave() async {
        await annotationChangeTask?.value
        await annotationCoordinator.flush()
    }
}
