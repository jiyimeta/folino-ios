import Domain
import EditorCore
import Foundation

/// Throwing away what this session changed, and leaving the file as it was when the session opened.
///
/// The unwinding, and what counts as an edit at all, are the core's (`EditorSessionCore+Revert.swift`). What is here
/// is the ordering that needs a run loop: cancel the debounce, join the save already running, unwind, then write the
/// unwound score back over the edited one.
extension EditorViewModel {
    public func discardSessionEdits() async {
        guard isSessionActive else { return }
        // Marked (and the retained stack dropped) even when there is nothing to unwind: leaving without edits must
        // not deposit a stack the user has just declined.
        core.markSessionDiscarded()
        historyStore.invalidate(core.scoreItem.id)
        guard core.sessionHasEdits else { return }

        autosaveTask?.cancel()
        autosaveTask = nil
        let pendingSave = inFlightSaveTask
        inFlightSaveTask = nil
        await pendingSave?.value

        unwindSessionEdits()
        // Only write if the unwind actually landed back where the session opened. It can fail to — an adopted
        // session's stack reaches back past this session's start — and half-unwound bytes are worse than the edits.
        guard !core.sessionHasEdits else { return }
        core.markDirtyForDiscardFlush()
        await flushPendingSave()
        await discardOriginalCapturedThisSession()
    }

    /// Walks this session's edits back to where it opened and publishes the result.
    ///
    /// Internal rather than private: the end-of-session tests drive it directly to assert what `sessionEndMode` says
    /// once a session has been unwound.
    func unwindSessionEdits() {
        core.unwindSessionEdits()
        syncFromCore()
        // `syncFromCore` announces a score only when the revision moved past the host's copy, and an unwind that
        // lands back on an identical score still has to be drawn — the pages in between were not.
        if let score = core.score { onScoreChanged(score) }
    }

    /// Takes back the original this session's first save captured, now that those edits are gone: a score whose only
    /// edits were just thrown away must not go on offering to revert to an original it is already identical to.
    private func discardOriginalCapturedThisSession() async {
        guard let cleared = await core.discardOriginalCapturedThisSession() else { return }
        hasCapturedOriginal = false
        try? await repository.saveScoreItem(cleared)
    }
}
