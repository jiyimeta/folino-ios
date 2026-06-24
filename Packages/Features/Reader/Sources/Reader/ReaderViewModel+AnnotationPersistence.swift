import Domain
import Foundation

// MARK: - Annotation persistence (M2 — per-stroke musical anchoring)

extension ReaderViewModel {
    /// Loads any persisted annotation layer for the current score into `annotationDrawings`. Called from `load()` once
    /// the score and preferences are ready.
    func loadAnnotations() async {
        let layer = try? await annotationStore.annotationLayer(forScoreItem: scoreItem.id)
        annotationDrawings = layer?.drawings ?? []
    }

    /// Called by the container on every canvas change with the freshly re-anchored drawings. Updates the in-memory
    /// model immediately (so a re-render projects the live ink, not a stale model) and debounces a save ~0.5 s; an
    /// empty model deletes the layer instead of storing an empty one.
    func annotationDrawingsDidChange(_ drawings: [DrawingAnchor]) {
        annotationDrawings = drawings
        pendingAnnotationDrawings = drawings
        annotationSaveTask?.cancel()
        let scoreID = scoreItem.id
        annotationSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            if Task.isCancelled { return }
            await self?.persistPendingAnnotation(scoreID: scoreID)
        }
    }

    /// Writes (or deletes) the pending model immediately. Safe when nothing is pending. Called before `advance` swaps
    /// the score and on VM teardown so no ink is lost mid-transition.
    func flushPendingAnnotationSave() async {
        annotationSaveTask?.cancel()
        annotationSaveTask = nil
        await persistPendingAnnotation(scoreID: scoreItem.id)
    }

    private func persistPendingAnnotation(scoreID: Domain.ScoreItemID) async {
        guard let drawings = pendingAnnotationDrawings else { return }
        pendingAnnotationDrawings = nil
        if drawings.isEmpty {
            try? await annotationStore.deleteAnnotationLayer(forScoreItem: scoreID)
            return
        }
        let layer = AnnotationLayer(
            scoreItemID: scoreID,
            drawings: drawings,
            textBoxes: [],
            updatedAt: Date(),
        )
        try? await annotationStore.saveAnnotationLayer(layer)
    }
}
