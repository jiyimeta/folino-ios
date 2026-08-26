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
    /// Whether this session has changed the score — the difference between ✕ closing the session and ✕ asking
    /// first, and what turns the session-end control yellow.
    ///
    /// The question is about the SCORE, not about a step count. `sessionEditDepth != 0` is only a fast, always-safe
    /// "yes": any non-zero net offset is a change, and the signed part matters because a session that net-UNDID an
    /// earlier session's work (negative depth) has changed the score too. What it cannot answer is a mixed run that
    /// nets back to zero — undo once into the previous session, then type a note — where the count says "untouched"
    /// over a score that is nowhere near where the session opened. `isAtSessionOpenScore` is the authority there,
    /// and reaching it costs one `Score` comparison.
    ///
    /// Order matters: the depth is tested first, so the deep compare only runs in the one case where the two can
    /// disagree. Outside a session this is `false` — there is no session to have edits — which is what lets view
    /// code read it unguarded.
    public var sessionHasEdits: Bool {
        guard isSessionActive else { return false }
        if sessionEditDepth != 0 {
            return true
        }
        return !isAtSessionOpenScore
    }

    /// The session's whole status readout, in one value.
    ///
    /// This session's own edits win over the revert offer deliberately: while you are mid-edit the thing you want is
    /// to keep or drop what you just did, not to be offered a rollback of everything. It also makes the control
    /// respond the instant you change a note, which is the point — `sessionEditDepth` moves on the edit itself,
    /// whereas the revert offer can only appear once a save has captured the original.
    public var sessionEndMode: EditorSessionEndMode {
        if sessionHasEdits {
            return .commitEdited
        }
        if canRevertToOriginal {
            return .revert
        }
        return .commitUnchanged
    }
}

extension EditorViewModel {
    /// Rewinds this session to the score it opened on, notifying the host a single time at the end.
    ///
    /// Score-only and store-agnostic: it touches neither `historyStore` nor the file, so it can be called on its
    /// own. Store bookkeeping (invalidate, deposit suppression) belongs to `discardSessionEdits()` below, its only
    /// production caller — it lives in this file to sit beside it, not because it shares its concerns.
    ///
    /// Count-driven, NOT `while canUndo`: with retained history the stack bottom no longer means "where this
    /// session started" — an adopted session can undo below its own start, and walking `canUndo` to exhaustion
    /// would silently discard PREVIOUS sessions' edits. `sessionEditDepth` is the signed net offset from session
    /// start, so undoing it (or redoing its negation) lands exactly on the session-open score from either
    /// direction.
    ///
    /// One notification rather than one per step: the host re-lays the score out on every `onScoreChanged`, so a
    /// long session would otherwise redraw the whole thing once per edit on the way back.
    ///
    /// The loops are the fast path, not the whole answer. `ScoreEditor.apply` clears the redo stack on every
    /// successful apply, so a session that undid below its own start and then typed a note has no redo left to walk
    /// forward with, and no undo that would help either — the loops stall with the depth unconsumed. Landing on
    /// `sessionOpenScore` is the fallback for exactly that, and it also answers the mixed run whose depth nets back
    /// to zero (one undo into an earlier session, one new edit) over a score nowhere near where it started. The
    /// cost is the earlier session's history, which the only production caller — the discard path — ends anyway.
    ///
    /// What must NOT happen is zeroing a depth the loops did not consume: that turns "the score is not at session
    /// start" into a silent success, and the discard path then writes those bytes to disk (review Critical 1).
    /// With no snapshot to land on, the residual depth is left standing as the signal that this failed.
    func unwindSessionEdits() async {
        guard let session else { return }
        while sessionEditDepth > 0, session.undo() {
            sessionEditDepth -= 1
        }
        while sessionEditDepth < 0, session.redo() {
            sessionEditDepth += 1
        }
        if let sessionOpenScore, sessionEditDepth != 0 || session.score != sessionOpenScore {
            // The snapshot gear throws this session away, and its part-id baseline with it. A mapping still standing
            // at that moment is the row's ONLY route back: the score is about to jump to the session-open parts
            // while the row sits in whatever numbering the last consume left it in, and the fresh session below
            // baselines on the post-jump parts — so it would read identity forever and nothing would ever reconcile
            // them (review Important 1). Reachable whenever a part edit was saved and then discarded: the save
            // re-baselined, the discard puts the removed part back, and the row still names the parts without it.
            //
            // The destination is the SNAPSHOT's parts, not the session's current ones. The session's own map ends at
            // wherever this session happens to have left the score, and the gear only runs when that is NOT the
            // snapshot — so migrating with it alone would land the row in an intermediate numbering that no file
            // ever has. Composing it with "where the current parts sit in the snapshot" puts the row into the
            // numbering the restored score has, which is what the file is about to be rewritten to hold. A part this
            // session removed and the snapshot still carries is dropped rather than restored: its id is gone from
            // the current score, so nothing here can name it.
            let restore = Self.partIndexMapping(from: session.score, to: sessionOpenScore)
            let mapping = Self.composing(session.partIndexMapping, restore)
            let migrated = mapping.allSatisfy { $0.value == $0.key }
                ? nil
                : await migratePartIndexedPreferences(mapping, in: session, for: scoreItem.id)
            self.session = ScoreEditSession(score: sessionOpenScore)
            sessionEditDepth = 0
            onPartIndicesRemapped(migrated)
        }
        generation += 1
        mutationTicket += 1
        rederiveSelection()
        if let current = self.session {
            onScoreChanged(current.score)
        }
    }

    /// Whether the live score still is the one this session opened on — the state `sessionEditDepth` is only a
    /// proxy for. Read by the discard path both to decide there is nothing to unwind and to refuse to write a score
    /// the unwind failed to land. `false` with no session or no snapshot: not knowing is not the same as knowing it
    /// matches.
    var isAtSessionOpenScore: Bool {
        guard let session, let sessionOpenScore else { return false }
        return session.score == sessionOpenScore
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
    /// "The way it was when the session opened" used to be exactly the bottom of `ScoreEditSession`'s undo stack.
    /// It is not, now that history outlives a session: an adopted session's stack bottom is where the PREVIOUS
    /// session started, and its redo stack — the only way back for a session that undid below its own start — is
    /// cleared by the next `apply`. So the walk back is `unwindSessionEdits()`'s job and it has two gears: the
    /// signed step count while the stacks still hold what it needs, and `sessionOpenScore` (a value copy taken by
    /// `beginSession`) when they don't.
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

        // ✕ is final (controller ruling over the spec's redo-survives reading), and that has to be settled BEFORE
        // the "nothing to unwind" exit below — a session that edited a note and undid it again is back at depth
        // zero with both stacks full, and letting that one out without marking it would deposit a history whose
        // redo replays exactly what ✕ threw away (review Minor 7). Unwinding via undo populates the redo stack the
        // same way, so a ✕ ends ALL retained history for this score whatever route it took here: the deposit is
        // suppressed and any retained entry dropped — the same contract as an app kill.
        didDiscardSession = true
        historyStore.invalidate(scoreItem.id)

        // Nothing of this session's own is on disk or in memory, so there is nothing to unwind — and in particular
        // nothing that would justify rewriting the file. One predicate, and deliberately the SAME one the ✕ button
        // gates its confirmation on: what ✕ throws away and what ✕ asks about have to be the same question, or a
        // session can be discarded without the user being asked (re-review Important 1).
        guard sessionHasEdits else { return }

        autosaveTask?.cancel()
        autosaveTask = nil
        let pendingSave = inFlightSaveTask
        inFlightSaveTask = nil
        await pendingSave?.value

        await unwindSessionEdits()

        // Refuse to write a score the unwind could not land. With a snapshot to fall back on this cannot fail, and
        // the guard is here for the case where it can — the file keeps this session's edits, which is recoverable,
        // where writing a half-unwound score is not (review Critical 1).
        guard sessionEditDepth == 0, isAtSessionOpenScore else { return }

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
