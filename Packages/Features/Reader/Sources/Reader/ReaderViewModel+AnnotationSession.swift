import Domain
import Foundation
import ReaderAnnotationCore

// MARK: - The annotation session's lifecycle and its three ways out

extension ReaderViewModel {
    /// What the strip's trailing control shows — see `AnnotationSessionEndMode`. Derived, never set: the canvas
    /// reports whether the session changed anything, the model says whether there is ink at all.
    var annotationSessionEndMode: AnnotationSessionEndMode {
        .derive(sessionHasChanges: annotationCanvasSession.hasChanges, hasInk: !annotationDrawings.isEmpty)
    }

    /// Toggle annotation (Apple Pencil) mode — the strip's pencil button on the way in, and every exit on the way
    /// out. Kept as a toggle because the coach-mark wiring and the tests drive it as one.
    func toggleAnnotation() {
        if isAnnotating {
            finishAnnotationSession()
        } else {
            beginAnnotationSession()
        }
    }

    /// Enter annotation mode. Remembers the ink as it stands so ✕ has something to go back to, and starts the
    /// analytics session (`annotation_started` now; the stroke count and duration ship as one `annotation_ended`).
    func beginAnnotationSession() {
        guard !isAnnotating else { return }
        annotationSessionBaseline = annotationDrawings
        annotationCanvasSession.reset()
        isAnnotating = true
        annotationStrokeCount = 0
        annotationSessionStart = Date()
        analytics.log(.annotationStarted())
    }

    /// ✓ — leave annotation mode keeping whatever the session drew. Nothing to write: every change was captured and
    /// handed to the save coordinator as it happened.
    func finishAnnotationSession() {
        guard isAnnotating else { return }
        isAnnotating = false
        annotationSessionBaseline = nil
        endAnnotationSessionIfNeeded()
    }

    /// ✕ — leave annotation mode and put the ink back the way it was when the session began. A session that changed
    /// nothing leaves without touching the layer, so the reseed (and the save it triggers) only happens when there
    /// is something to undo.
    func discardAnnotationSession() {
        guard isAnnotating else { return }
        let baseline = annotationSessionBaseline
        let hadChanges = annotationCanvasSession.hasChanges
        finishAnnotationSession()
        guard hadChanges, let baseline else { return }
        replaceAnnotationLayer(with: baseline)
    }

    /// The annotation layer's "revert to original": leave annotation mode and delete every annotation on the score.
    /// Offered only when the session itself changed nothing (`AnnotationSessionEndMode.clearAll`), and confirmed
    /// before it gets here.
    func clearAllAnnotations() {
        guard isAnnotating else { return }
        finishAnnotationSession()
        replaceAnnotationLayer(with: [])
    }

    /// Swap the whole layer for `drawings`, on screen and in the store. The reseed ticket is what makes the containers
    /// redraw: they deliberately do not observe `annotationDrawings` (see the ticket's own doc comment), because
    /// while the user draws the canvas is the source of truth. Here the model really has moved under the canvas and
    /// the canvas is wrong — the one situation the ticket exists for.
    ///
    /// Written through `annotationDrawingsDidChange` rather than straight to the coordinator so the part-migration
    /// guards there still hold: a layer replaced while a part edit's migration is unsettled would corrupt the ink the
    /// same way a capture would.
    private func replaceAnnotationLayer(with drawings: [DrawingAnchor]) {
        annotationDrawingsDidChange(drawings)
        annotationReseedTicket += 1
    }
}
