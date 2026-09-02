#if os(iOS)
import Foundation
import PencilKit
import ReaderAnnotationCore

// What the controller tells the strip about the session in progress — undo / redo availability and whether the ink
// has changed — and the undo history behind it. Split out of `AnnotationCanvasView.swift` to keep that file inside
// SwiftLint's file-length budget; the stored properties it works on stay declared with the controller.
//
// The history is the app's, not PencilKit's — see `AnnotationCanvasSession`. PencilKit's own undo manager is still
// what a three-finger swipe and the iPad palette's buttons drive, so it is left alone while the user draws (its
// changes reach `canvasViewDrawingDidChange` like any other and are classified by bytes), and emptied whenever this
// controller sets the drawing itself: after a programmatic set its actions would restore a state the canvas no
// longer stands on.

extension AnnotationCanvasController {
    /// The current page's history, created from the canvas's present bytes on first sight of the page.
    private var currentHistory: AnnotationPageHistory? {
        get { canvasSession?.histories[historyKey] }
        set { canvasSession?.histories[historyKey] = newValue }
    }

    /// A change the canvas reported — the user's stroke, a swipe undo, or the echo of a set this controller made.
    /// Files it into the page's history and republishes.
    func recordCanvasChange(_ drawing: PKDrawing) {
        guard canvasSession != nil else { return }
        let bytes = drawing.dataRepresentation()
        if var history = currentHistory {
            history.record(bytes)
            currentHistory = history
        } else {
            currentHistory = AnnotationPageHistory(current: bytes)
        }
        publishSessionState()
    }

    /// The canvas was just set programmatically to the same ink in a new spelling (a reseed on re-entry or a page
    /// turn): respell the page's current state so the history neither records it as an edit nor loses its place.
    /// A page with no history yet simply starts here.
    func rebaseHistory(to drawing: PKDrawing) {
        guard canvasSession != nil else { return }
        let bytes = drawing.dataRepresentation()
        if var history = currentHistory {
            history.rebase(current: bytes)
            currentHistory = history
        } else {
            currentHistory = AnnotationPageHistory(current: bytes)
        }
        canvas?.undoManager?.removeAllActions()
        publishSessionState()
    }

    /// `hasChanges` as of this instant — the latch from earlier pages, or the current page having left its seed.
    var sessionHasChangesNow: Bool {
        guard let canvas, let seed = sessionSeedBytes else { return false }
        return changedOnEarlierPages || canvas.drawing.dataRepresentation() != seed
    }

    /// Republish undo / redo availability and `hasChanges` to the strip. Cheap enough to call on every change: one
    /// `dataRepresentation()` of the current page's drawing.
    func publishSessionState() {
        guard let canvasSession else { return }
        canvasSession.canUndo = currentHistory?.canUndo ?? false
        canvasSession.canRedo = currentHistory?.canRedo ?? false
        canvasSession.hasChanges = sessionHasChangesNow
    }

    /// The session starts when the tool picker goes up: remember the seed, respell the page's current state to what
    /// the canvas holds now (a paged reader empties and reseeds it between sessions), and wire the strip's undo /
    /// redo.
    func beginSessionTracking() {
        guard let canvas else { return }
        sessionSeedBytes = canvas.drawing.dataRepresentation()
        changedOnEarlierPages = false
        rebaseHistory(to: canvas.drawing)
        canvasSession?.performUndo = { [weak self] in self?.restoreFromHistory(\.undoTarget) }
        canvasSession?.performRedo = { [weak self] in self?.restoreFromHistory(\.redoTarget) }
        publishSessionState()
    }

    /// Mirror of `beginSessionTracking`, run when the tool picker comes down. The history stays — it is what the
    /// next session undoes into; only the session's own state goes.
    func endSessionTracking() {
        canvas?.undoManager?.removeAllActions()
        sessionSeedBytes = nil
        changedOnEarlierPages = false
        canvasSession?.performUndo = nil
        canvasSession?.performRedo = nil
        canvasSession?.reset()
    }

    /// Set the canvas to the history's neighbouring snapshot. The set's echo comes back through
    /// `canvasViewDrawingDidChange`, where the bytes match that snapshot and the cursor moves — the same path a
    /// swipe undo takes, so the two can never disagree about where the history stands. The echo also has to be
    /// CAPTURED, which is why the page-turn echo guard is lowered first: after a turn onto a page with history, the
    /// first thing the user does may be this, and the model has to follow.
    private func restoreFromHistory(_ target: KeyPath<AnnotationPageHistory, Data?>) {
        guard let canvas, let bytes = currentHistory?[keyPath: target],
              let drawing = try? PKDrawing(data: bytes) else { return }
        ignoreEchoesUntilUserDraws = false
        canvas.undoManager?.removeAllActions()
        canvas.drawing = drawing
    }
}
#endif
