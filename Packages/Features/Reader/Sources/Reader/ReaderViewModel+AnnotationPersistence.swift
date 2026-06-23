import Domain
import Foundation

// MARK: - Annotation persistence (M1 degenerate — whole-canvas blob)

extension ReaderViewModel {
    /// All-zero anchor used for M1's whole-canvas blob. Carries no musical meaning; M2 anchors per stroke.
    static func makeSentinelAnchor() -> MusicalAnchor {
        MusicalAnchor(
            measureIndex: 0, tickInMeasure: 0, partIndex: 0,
            staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
    }

    /// Loads any persisted annotation layer for the current score and populates `annotationDrawingData`. Called from
    /// `load()` immediately after the score and preferences are ready.
    func loadAnnotations() async {
        let layer = try? await annotationStore.annotationLayer(forScoreItem: scoreItem.id)
        annotationDrawingData = layer?.drawings.first?.encodedDrawing
    }

    /// Called by the canvas coordinator on every drawing change. Debounces a save ~0.5 s; an empty drawing deletes the
    /// layer instead of storing an empty blob.
    func annotationDrawingDidChange(_ data: Data, isEmpty: Bool) {
        // Keep the in-memory source of truth in sync with the canvas immediately. Without this, a later re-render
        // would feed the canvas the STALE `annotationDrawingData` and the echo guard would re-seed (erase) the live
        // ink. The DB write stays debounced below; this is just the displayed/observed value.
        annotationDrawingData = data
        pendingAnnotationData = data
        pendingAnnotationIsEmpty = isEmpty
        annotationSaveTask?.cancel()
        let scoreID = scoreItem.id
        annotationSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            if Task.isCancelled { return }
            await self?.persistPendingAnnotation(scoreID: scoreID)
        }
    }

    /// Writes (or deletes) the pending drawing immediately. Safe to call when nothing is pending. Called before
    /// `advance` swaps the score and on VM teardown so no data is lost mid-transition.
    func flushPendingAnnotationSave() async {
        annotationSaveTask?.cancel()
        annotationSaveTask = nil
        await persistPendingAnnotation(scoreID: scoreItem.id)
    }

    private func persistPendingAnnotation(scoreID: Domain.ScoreItemID) async {
        guard let data = pendingAnnotationData else { return }
        pendingAnnotationData = nil
        if pendingAnnotationIsEmpty {
            try? await annotationStore.deleteAnnotationLayer(forScoreItem: scoreID)
            return
        }
        let layer = AnnotationLayer(
            scoreItemID: scoreID,
            drawings: [DrawingAnchor(anchor: Self.makeSentinelAnchor(), encodedDrawing: data)],
            textBoxes: [],
            updatedAt: Date(),
        )
        try? await annotationStore.saveAnnotationLayer(layer)
    }
}
