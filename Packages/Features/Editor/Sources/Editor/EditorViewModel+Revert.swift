import Domain
import Foundation

extension EditorViewModel {
    /// Reads the observed mirror, not `scoreItem` — `scoreItem` is `@ObservationIgnored`, so a toolbar bound to it
    /// would not notice the capture that the session's first autosave performs.
    public var canRevertToOriginal: Bool {
        hasCapturedOriginal
    }

    /// Whether the sidecar this session would revert to is the PDF conversion's output rather than the file the
    /// user actually imported. The toolbar's wording must not call that "the original" — the imported PDF is a
    /// separate, distinct original sitting in the same sheet (design spec, "Two originals must never be called the
    /// same thing"; Important 5 review fix). Read alongside `canRevertToOriginal` in the same body pass that
    /// recomputes it, so the `@ObservationIgnored` read below is never stale when it matters.
    ///
    /// Internal, not `public`: only `EditorTopBarView.swift`, in this same module, reads it (re-review fix).
    var revertsToConversionOutput: Bool {
        scoreItem.originalProvenance == .conversionOutput
    }

    /// What the confirmation has to say. The annotation half is the host's to answer — the Editor cannot see the ink.
    public func revertWarnings(hasMusicalAnnotations: Bool) -> RevertWarnings {
        RevertPolicy.warnings(for: scoreItem, hasMusicalAnnotations: hasMusicalAnnotations)
    }

    /// Puts the original's bytes back and tears the session down.
    ///
    /// Deliberately NOT via `endSession()`: that flushes the pending autosave, which would write the edits this is
    /// discarding a moment before discarding them. The debounce is cancelled up front so it cannot fire mid-revert,
    /// `isReverting` closes off any later flush trigger (scene-background, `endSession`) for the rest of this call,
    /// and any save already past `performSave()`'s entry guard is joined before this method touches the file
    /// (Critical 2 review fix) — see the inline comments below for how each piece does its part.
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
        // Set synchronously, before any `await`: `performSave()`'s entry guard honours this immediately, closing
        // off any flush that starts from here on (scene-background, `endSession`) even before the wait below
        // completes (Critical 2 review fix).
        isReverting = true
        autosaveTask?.cancel()
        autosaveTask = nil
        // A save can already be past `performSave()`'s entry guard and suspended inside `captureOriginalIfNeeded` —
        // cancelling the debounce above does not reach it. Wait for it to finish (it will see `isReverting` and
        // bail before writing, or — if it slipped through just ahead of the flag — finish its own write) before
        // this method touches the file itself, so the two can never interleave (Critical 2 review fix).
        let pendingSave = inFlightSaveTask
        inFlightSaveTask = nil
        await pendingSave?.value

        let reverted: ScoreItem
        do {
            reverted = try await originalStore.revertToOriginal(scoreItem, restoringScoreInfo: false)
        } catch {
            revertError = String(localized: "editor.revert.failed.message", bundle: .module)
            // The session stays open and live edits still need protecting, so the guard set above must not
            // outlive this failed attempt.
            isReverting = false
            scheduleAutosave()
            return
        }

        // The file no longer relates to any retained history for this score, and waiting for the lazy hash
        // mismatch would hold a dead multi-MB session in one of three slots. The live session is torn down below
        // without deposit, as today.
        historyStore.invalidate(scoreItem.id)

        // The file is the original now, no matter what happens below — nothing past this point may touch isDirty
        // or the debounce again. `isReverting` also resets here, not just on the failure path below: this view
        // model is reused across every edit session a Reader screen opens, and leaving it `true` would silently
        // disable `performSave()` for every session after this one.
        scoreItem = reverted
        hasCapturedOriginal = false
        isDirty = false
        isReverting = false
        do {
            try await repository.saveScoreItem(reverted)
        } catch {
            revertError = String(localized: "editor.revert.failed.message", bundle: .module)
        }
        // Drop the session last: `canUndo` reads through it, so the toolbar goes inert only once the score on disk
        // is actually the original.
        session = nil
        sessionOpenScore = nil
        selection = .none
        selectedItem = nil
        caretItem = nil
        // The host is holding the edited score and drawing it; leaving the session open would leave the user
        // looking at the very edits this just discarded. Ending it is also what stops playback before the file
        // underneath the engine changes.
        onRevertCompleted(reverted)
    }
}
