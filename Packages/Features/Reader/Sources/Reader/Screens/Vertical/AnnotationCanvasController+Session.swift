#if os(iOS)
import Foundation
import PencilKit

// What the controller tells the strip about the session in progress — undo / redo availability and whether the ink
// has changed — and the bookkeeping behind it. Split out of `AnnotationCanvasView.swift` to keep that file inside
// SwiftLint's file-length budget; the stored properties it works on stay declared with the controller.

extension AnnotationCanvasController {
    /// `hasChanges` as of this instant — the latch from earlier pages, or the current page having left its seed.
    var sessionHasChangesNow: Bool {
        guard let canvas, let seed = sessionSeedBytes else { return false }
        return changedOnEarlierPages || canvas.drawing.dataRepresentation() != seed
    }

    /// Republish undo / redo availability and `hasChanges` to the strip. Cheap enough to call on every change: one
    /// `dataRepresentation()` of the current page's drawing.
    func publishSessionState() {
        guard let canvasSession, let canvas else { return }
        let manager = canvas.undoManager
        canvasSession.canUndo = manager?.canUndo ?? false
        canvasSession.canRedo = manager?.canRedo ?? false
        canvasSession.hasChanges = sessionHasChangesNow
    }

    /// The session starts when the tool picker goes up: remember the seed, wire the strip's undo / redo to the
    /// canvas's own undo manager, and watch that manager so a three-finger swipe (which never comes through here)
    /// still updates the buttons.
    func beginSessionTracking() {
        guard let canvas else { return }
        sessionSeedBytes = canvas.drawing.dataRepresentation()
        changedOnEarlierPages = false
        canvas.undoManager?.removeAllActions()
        canvasSession?.performUndo = { [weak canvas] in canvas?.undoManager?.undo() }
        canvasSession?.performRedo = { [weak canvas] in canvas?.undoManager?.redo() }
        let names: [Notification.Name] = [
            .NSUndoManagerCheckpoint, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
            .NSUndoManagerDidCloseUndoGroup,
        ]
        let center = NotificationCenter.default
        undoObservers = names.map { name in
            center.addObserver(forName: name, object: canvas.undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishSessionState() }
            }
        }
        publishSessionState()
    }

    /// Mirror of `beginSessionTracking`, run when the tool picker comes down. The undo stack goes with the session:
    /// what was drawn is committed the moment it is captured, and there is no strip to undo it from any more.
    func endSessionTracking() {
        for observer in undoObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        undoObservers = []
        canvas?.undoManager?.removeAllActions()
        sessionSeedBytes = nil
        changedOnEarlierPages = false
        canvasSession?.performUndo = nil
        canvasSession?.performRedo = nil
        canvasSession?.reset()
    }
}
#endif
