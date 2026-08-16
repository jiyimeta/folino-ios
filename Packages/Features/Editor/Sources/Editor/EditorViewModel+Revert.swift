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
    /// discarding a moment before discarding them. The debounce is cancelled up front so it cannot fire mid-revert —
    /// but `isDirty` is left alone until the revert actually succeeds. Clearing it early would tell a later flush
    /// (the scene going inactive, say) there is nothing to protect, and a failed revert leaves the pre-revert edit
    /// still live in the score with the session still open: silently losing that edit on top of a failed revert
    /// would compound one failure into two. On failure the debounce is rescheduled so that edit stays protected.
    ///
    /// If `originalStore.revertToOriginal` succeeds but `repository.saveScoreItem` then throws, the file on disk is
    /// already the original while the row's hash still describes the edited version. This is the same benign,
    /// self-correcting mismatch the design doc's "Atomicity" section accepts for the store's own crash-mid-swap case
    /// (`docs/superpowers/specs/2026-08-16-revert-to-original-design.md`): the file is what the reader opens, so the
    /// user sees their original and loses nothing, and the stale hash heals on the next save or revert. No retry is
    /// attempted here — retrying would call `revertToOriginal` again on an item whose sidecar it already consumed,
    /// which throws `DomainError.scoreFileNotFound`. That's safe, but not a repair, so there is nothing to gain.
    public func revertToOriginal() async {
        revertError = nil
        autosaveTask?.cancel()
        autosaveTask = nil
        do {
            let reverted = try await originalStore.revertToOriginal(scoreItem, restoringScoreInfo: false)
            try await repository.saveScoreItem(reverted)
            scoreItem = reverted
            hasCapturedOriginal = false
            isDirty = false
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
            // The session is still open and the pre-revert edit is still live in the score — reschedule the
            // debounce this method cancelled on entry so that edit is not silently dropped by a later flush.
            // A no-op when there was nothing dirty to begin with: `performSave` itself guards on `isDirty`.
            scheduleAutosave()
        }
    }
}
