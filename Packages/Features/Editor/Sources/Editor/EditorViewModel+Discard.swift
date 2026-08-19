import Domain
import Foundation

/// Which of the three things the strip's single trailing control currently is. Derived from the session, never set —
/// see `EditorSessionEndButton`, which draws it, and `EditorTopBarView`, which needs to know its width class to
/// decide whether the row can fold at all.
public enum EditorSessionEndMode {
    /// Checkmark on plain glass — the score matches the original.
    case commitUnchanged
    /// Revert on red — the score differs from the original and this session did not do it. The only wide state.
    case revert
    /// Checkmark on yellow — this session changed something.
    case commitEdited
}

extension EditorViewModel {
    /// The session's whole status readout, in one value.
    ///
    /// This session's own edits win over the revert offer deliberately: while you are mid-edit the thing you want is
    /// to keep or drop what you just did, not to be offered a rollback of everything. It also makes the control
    /// respond the instant you change a note, which is the point — `sessionEditDepth` moves on the edit itself,
    /// whereas the revert offer can only appear once a save has captured the original.
    public var sessionEndMode: EditorSessionEndMode {
        if sessionHasEdits { return .commitEdited }
        if canRevertToOriginal { return .revert }
        return .commitUnchanged
    }
}

extension EditorViewModel {
    /// Looks for an original that is on disk but missing from the row, and adopts it.
    ///
    /// Called when a session opens, because that is when the answer is needed: the strip offers revert on the
    /// strength of the row alone, and a row can legitimately be behind. A capture writes the sidecar, then the score,
    /// then the row — kill the app between the last two and the edit survives while the row forgets, leaving a score
    /// that is not what was imported and says it is. Nothing else notices until the next save.
    ///
    /// Costs nothing when there is nothing to find: `adoptOrphanedOriginal` never copies, so on a score that has
    /// never been edited it looks for a file that isn't there and returns the item untouched.
    public func reconcileCapturedOriginal() async {
        guard !hasCapturedOriginal, !isReverting else { return }
        let adopted = await originalStore.adoptOrphanedOriginal(for: scoreItem)
        guard adopted.canRevertToOriginal else { return }
        scoreItem = adopted
        hasCapturedOriginal = true
        // The row is the thing that was wrong; write it back so the next launch doesn't have to work this out again.
        try? await repository.saveScoreItem(adopted)
    }

    /// Throws away everything this session did and puts the file back the way it was when the session opened.
    ///
    /// "The way it was when the session opened" is exactly the bottom of `ScoreEditSession`'s undo stack:
    /// `beginSession` builds a fresh session around the loaded score, so unwinding until it can undo no more lands
    /// on that score and nowhere else. That is why this is not a byte snapshot — the stack already IS the snapshot,
    /// and keeping a second copy of the file would be one more thing to get out of step.
    ///
    /// Autosave is the reason this has to touch the disk at all. By the time the user reaches for ✕ the debounce has
    /// very likely already written this session's edits, so rewinding memory is not enough: the restored score has to
    /// go back over them. The choreography around that write mirrors `revertToOriginal()` — cancel the debounce,
    /// join any save already past `performSave()`'s entry guard, and only then write — because the same interleaving
    /// would be just as destructive here.
    ///
    /// Distinct from `revertToOriginal()`, and the two must not be confused: revert goes back to the bytes the score
    /// was imported with, discarding every session that ever ran. This goes back one session.
    public func discardSessionEdits() async {
        guard session != nil else { return }

        // Nothing of this session's own is on disk or in memory, so there is nothing to unwind — and in particular
        // nothing that would justify rewriting the file.
        guard sessionHasEdits else { return }

        autosaveTask?.cancel()
        autosaveTask = nil
        let pendingSave = inFlightSaveTask
        inFlightSaveTask = nil
        await pendingSave?.value

        unwindSessionEdits()

        // Unconditionally dirty: whether or not the debounce got to run, the file is now either this session's edits
        // or the pre-session score, and only a write can settle which.
        isDirty = true
        await flushPendingSave()

        if capturedOriginalThisSession {
            await discardOriginalCapturedThisSession()
        }
    }

    /// Takes back the sidecar this session's first save created. Best-effort: if it fails the score is still correct
    /// on disk, and the only cost is a revert control offering to restore an original the score already matches —
    /// the same benign, self-correcting mismatch `revertToOriginal()` accepts between file and row.
    private func discardOriginalCapturedThisSession() async {
        guard let cleared = try? await originalStore.discardOriginal(for: scoreItem) else { return }
        scoreItem = cleared
        hasCapturedOriginal = false
        capturedOriginalThisSession = false
        try? await repository.saveScoreItem(cleared)
    }
}
