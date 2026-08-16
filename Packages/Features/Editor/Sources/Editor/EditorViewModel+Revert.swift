import Domain
import Foundation

extension EditorViewModel {
    /// Reads the observed mirror, not `scoreItem` — `scoreItem` is `@ObservationIgnored`, so a toolbar bound to it
    /// would not notice the capture that the session's first autosave performs.
    public var canRevertToOriginal: Bool {
        hasCapturedOriginal
    }

    /// What the confirmation has to say. The annotation half is the host's to answer — the Editor cannot see the ink.
    public func revertWarnings(hasMusicalAnnotations: Bool) -> RevertWarnings {
        RevertPolicy.warnings(for: scoreItem, hasMusicalAnnotations: hasMusicalAnnotations)
    }

    /// Puts the original's bytes back and tears the session down.
    ///
    /// Deliberately NOT via `endSession()`: that flushes the pending autosave, which would write the edits this is
    /// discarding a moment before discarding them. The debounce is cancelled instead, and `isDirty` cleared so a
    /// later flush — the scene going inactive, say — cannot resurrect them either.
    public func revertToOriginal() async {
        revertError = nil
        autosaveTask?.cancel()
        autosaveTask = nil
        isDirty = false
        do {
            let reverted = try await originalStore.revertToOriginal(scoreItem, restoringScoreInfo: false)
            try await repository.saveScoreItem(reverted)
            scoreItem = reverted
            hasCapturedOriginal = false
            // Drop the editor last: `canUndo` reads through it, so the toolbar goes inert only once the score on
            // disk is actually the original.
            editor = nil
            selection = .none
            selectedItem = nil
            caretItem = nil
            // The host is holding the edited score and drawing it; leaving the session open would leave the user
            // looking at the very edits this just discarded. Ending it is also what stops playback before the file
            // underneath the engine changes.
            onRevertCompleted(reverted)
        } catch {
            revertError = String(localized: "editor.revert.failed", bundle: .module)
        }
    }
}
