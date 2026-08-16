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
    /// discarding a moment before discarding them. The debounce is cancelled up front so it cannot fire mid-revert.
    ///
    /// The two `await`s below need OPPOSITE failure handling, because only the first one touches the file:
    ///
    /// - While `originalStore.revertToOriginal` is in flight, the file is still whatever it was — if it throws, the
    ///   pre-revert edit is untouched and exactly as live as it was before this call. `isDirty` is left alone and
    ///   the debounce this method cancelled on entry is rescheduled, so that edit stays protected against a later
    ///   flush (the scene going inactive, say). The session stays open and nothing else about it changes.
    /// - The moment `revertToOriginal` RETURNS, the file on disk already IS the original — the store's write and
    ///   sidecar cleanup have happened. From here `isDirty` becomes `false` and nothing may schedule another write
    ///   for the rest of this session: the in-memory score is still the edited version, and an autosave firing after
    ///   this point would write it straight back over the file this just restored, silently erasing the revert with
    ///   no sidecar left to recover it from. If `repository.saveScoreItem` then throws, the row simply didn't
    ///   persist — the file is already correct, and that mismatch (correct bytes, stale row) is the same benign,
    ///   self-correcting state the design doc's "Atomicity" section accepts for the store's own crash-mid-swap case
    ///   (`docs/superpowers/specs/2026-08-16-revert-to-original-design.md`): it heals on the next save or revert, and
    ///   retrying here would only call `revertToOriginal` again on an item whose sidecar it already consumed —
    ///   `DomainError.scoreFileNotFound`, safe but not a repair. So no retry and no rescheduled autosave; the
    ///   teardown below still runs unconditionally, because the disk truth is the original and the reload the host
    ///   performs after `onRevertCompleted` needs to see that.
    public func revertToOriginal() async {
        revertError = nil
        autosaveTask?.cancel()
        autosaveTask = nil

        let reverted: ScoreItem
        do {
            reverted = try await originalStore.revertToOriginal(scoreItem, restoringScoreInfo: false)
        } catch {
            revertError = String(localized: "editor.revert.failed", bundle: .module)
            scheduleAutosave()
            return
        }

        // The file is the original now, no matter what happens below — nothing past this point may touch isDirty
        // or the debounce again.
        scoreItem = reverted
        hasCapturedOriginal = false
        isDirty = false
        do {
            try await repository.saveScoreItem(reverted)
        } catch {
            revertError = String(localized: "editor.revert.failed", bundle: .module)
        }
        // Drop the editor last: `canUndo` reads through it, so the toolbar goes inert only once the score on disk is
        // actually the original.
        editor = nil
        selection = .none
        selectedItem = nil
        caretItem = nil
        // The host is holding the edited score and drawing it; leaving the session open would leave the user
        // looking at the very edits this just discarded. Ending it is also what stops playback before the file
        // underneath the engine changes.
        onRevertCompleted(reverted)
    }
}
