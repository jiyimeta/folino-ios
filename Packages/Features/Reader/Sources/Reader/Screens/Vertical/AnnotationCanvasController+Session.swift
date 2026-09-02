#if os(iOS)
import Foundation
import PencilKit

// What the controller tells the strip about the session in progress — undo / redo availability and whether the ink
// has changed — and how the per-page undo managers reach the canvas. Split out of `AnnotationCanvasView.swift` to
// keep that file inside SwiftLint's file-length budget; the stored properties it works on stay declared with the
// controller.
//
// The history is PencilKit's own, on a manager we supply per page — see `AnnotationCanvasSession`. The strip's undo
// and redo drive that manager exactly as the palette's buttons and a three-finger swipe do, so the three can never
// disagree; this controller only watches it, to keep the strip's buttons current.

extension AnnotationCanvasController {
    /// Point the canvas at `historyKey`'s undo manager and watch it. Called whenever the key changes — a page turn,
    /// or the first `update` — and at session start, so a canvas that outlived a `clearHistory` re-attaches.
    func attachUndoManager() {
        guard let canvas, let canvasSession else { return }
        let manager = canvasSession.undoManager(for: historyKey)
        if canvas.pageUndoManager !== manager {
            canvas.pageUndoManager = manager
        }
        for observer in undoObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        let names: [Notification.Name] = [
            .NSUndoManagerCheckpoint, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
            .NSUndoManagerDidCloseUndoGroup,
        ]
        let center = NotificationCenter.default
        undoObservers = names.map { name in
            center.addObserver(forName: name, object: manager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishSessionState() }
            }
        }
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
        guard let canvasSession, let canvas else { return }
        let manager = canvas.undoManager
        canvasSession.canUndo = manager?.canUndo ?? false
        canvasSession.canRedo = manager?.canRedo ?? false
        canvasSession.hasChanges = sessionHasChangesNow
    }

    /// The session starts when the tool picker goes up: remember the seed and wire the strip's undo / redo to the
    /// canvas's manager. The manager itself is left exactly as the last session left it — that is the point.
    func beginSessionTracking() {
        guard let canvas else { return }
        sessionSeedBytes = canvas.drawing.dataRepresentation()
        changedOnEarlierPages = false
        canvasSession?.performUndo = { [weak canvas] in canvas?.undoManager?.undo() }
        canvasSession?.performRedo = { [weak canvas] in canvas?.undoManager?.redo() }
        attachUndoManager()
    }

    /// Mirror of `beginSessionTracking`, run when the tool picker comes down. The history stays — it is what the
    /// next session undoes into; only the session's own state goes.
    func endSessionTracking() {
        sessionSeedBytes = nil
        changedOnEarlierPages = false
        canvasSession?.performUndo = nil
        canvasSession?.performRedo = nil
        canvasSession?.reset()
    }
}
#endif
