import Domain
import EditorCore
import Foundation

/// Going back to the file as it was imported.
///
/// The core decides and performs it (`EditorSessionCore.revertToOriginal()`); what is here is the part that needs a
/// run loop and a screen — outrunning the save already in flight, persisting the row the store handed back, and
/// turning a failure into a message.
extension EditorViewModel {
    public func revertToOriginal() async {
        revertError = nil
        // Latched first, before any await: a save that starts while we are joining the one already in flight must
        // refuse rather than write the edited score back over the original.
        core.beginReverting()
        // Stop the debounce and join whatever is already writing, BEFORE the store touches the file: a save that
        // lands after the original is restored would put the edited score straight back.
        autosaveTask?.cancel()
        autosaveTask = nil
        let pendingSave = inFlightSaveTask
        inFlightSaveTask = nil
        await pendingSave?.value

        // The retained stack is addressed to a score that is about to stop existing.
        historyStore.invalidate(core.scoreItem.id)
        let reverted: ScoreItem
        do {
            reverted = try await core.revertToOriginal()
        } catch {
            revertError = String(localized: "editor.revert.failed.message", bundle: .module)
            // The session is still live and still possibly dirty, so the timer goes back on.
            scheduleAutosave()
            return
        }
        hasCapturedOriginal = false
        syncFromCore()
        do {
            try await repository.saveScoreItem(reverted)
        } catch {
            // The file is already the original; only the row failed to follow. Say so rather than silently leaving
            // the library describing a score that is no longer there.
            revertError = String(localized: "editor.revert.failed.message", bundle: .module)
        }
        onRevertCompleted(reverted)
    }
}
