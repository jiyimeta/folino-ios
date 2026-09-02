import Domain
import EditorCore
import Foundation

/// Going back to the file as it was imported.
///
/// The core decides and performs it (`EditorSessionCore.revertToOriginal()`); what is here is the part that needs a
/// run loop and a screen — outrunning the save already in flight, persisting the row the store handed back, and
/// turning a failure into a message.
extension EditorViewModel {
    /// The confirmation a revert shows: the base wording plus whichever caveats this score earns (`RevertPolicy`).
    /// On the view model rather than in a button because two hosts present it — the iOS session-end button as a
    /// popover, the Mac's File ▸ Revert To ▸ Original as an alert — and the composition must not fork.
    public func revertConfirmationMessage(hasMusicalAnnotations: Bool) -> String {
        let warnings = revertWarnings(hasMusicalAnnotations: hasMusicalAnnotations)
        var lines = [String(localized: "editor.revert.confirm.body", bundle: .module)]
        if warnings.contains(.musicalAnnotationsMayShift) {
            lines.append(String(localized: "editor.revert.confirm.inkMayShift", bundle: .module))
        }
        if warnings.contains(.originalMayNotBeImportTime) {
            lines.append(String(localized: "editor.revert.confirm.mayNotBeImport", bundle: .module))
        }
        return lines.joined(separator: "\n\n")
    }

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
