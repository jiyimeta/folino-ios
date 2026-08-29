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
            if Task.isCancelled { return }
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
            await core.performSave()
            syncFromCore()
        }
        inFlightSaveTask = task
        await task.value
    }
}
