import Domain
import EditorCore
import Foundation

/// The autosave debounce, and the handle a revert needs on whatever save is already running.
///
/// The write itself — where, in what format, the original captured before it and the row refreshed after — is
/// `EditorSessionCore.performSave()`. What lives here is the timer and the `Task`, which belong where the run loop
/// is.
extension EditorViewModel {
    /// Debounced 2 s after the last mutation; cancelled and rescheduled on each. Mirrors the Reader's annotation
    /// debounce pattern (ReaderViewModel+AnnotationPersistence.swift:17-34).
    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled {
                return
            }
            await self?.runSave()
        }
    }

    /// Cancel the debounce and write now. Safe when nothing is pending. Called by `endSession` and on
    /// scene-background.
    public func flushPendingSave() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        await runSave()
    }

    /// Wraps the core's save in a tracked `Task`, from either trigger site, so `revertToOriginal()` can await
    /// whatever save is already running before it does anything to the file itself: cancelling `autosaveTask` does
    /// not reach a call already past `performSave()`'s entry guard.
    ///
    /// Chained onto the PREVIOUS `inFlightSaveTask`, not just overwriting it: without the chain, a `runSave()`
    /// starting while an earlier one is still suspended in `captureOriginalIfNeeded` would drop that earlier handle,
    /// and `revertToOriginal()` — which only ever reads the latest one — would join just the newer call. Chaining
    /// keeps `inFlightSaveTask` at any moment a handle whose completion implies every save queued before it has also
    /// finished.
    private func runSave() async {
        let previous = inFlightSaveTask
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            // The session is pinned alongside the save, not re-read after it. A `beginSession` landing in one of
            // `performSave`'s suspension windows installs a session whose part-id baseline is the POST-edit order —
            // reading `core.session` at the migration would find that one, see identity, and leave the row in the
            // numbering the file has left.
            let sessionAtEntry = core.session
            let wrote = await core.performSave()
            syncFromCore()
            // The part-index migration rides the save, immediately after it — the closest the score and the row ever
            // are: the file has just been given the new part order, so a row migrated now describes the file that was
            // written. It runs ONLY when the write actually landed, because a save that bailed at its entry guard or
            // failed left the file in the OLD numbering, and migrating the row to the new one would be the very
            // corruption this exists to prevent.
            guard wrote, let sessionAtEntry, !sessionAtEntry.isPartMappingIdentity else { return }
            lastAppliedPartMapping = await migratePartIndexedState(in: sessionAtEntry, for: core.scoreItem.id)
        }
        inFlightSaveTask = task
        await task.value
    }
}
