import Domain
import EditorCore
import Foundation

/// The autosave debounce. The write itself — where, in what format, and the row refresh after it — is
/// `EditorSessionCore.performSave()`; what lives here is the timer, which belongs where the run loop is.
extension EditorViewModel {
    /// Debounced 2 s after the last mutation; cancelled and rescheduled on each. Mirrors the Reader's annotation
    /// debounce pattern (ReaderViewModel+AnnotationPersistence.swift:17-34).
    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            await self?.core.performSave()
            self?.syncFromCore()
        }
    }

    /// Cancel the debounce and write now. Safe when nothing is pending. Called by `endSession` and on
    /// scene-background.
    public func flushPendingSave() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        await core.performSave()
        syncFromCore()
    }
}
