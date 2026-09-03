import Domain
import EditorCore
import Foundation

/// Throwing away what this session changed, and leaving the file as it was when the session opened.
///
/// The unwinding, and what counts as an edit at all, are the core's (`EditorSessionCore+Revert.swift`). What is here
/// is the ordering that needs a run loop: cancel the debounce, join the save already running, unwind, then write the
/// unwound score back over the edited one.
extension EditorViewModel {
    /// The confirmation a discard shows. Same reason as `revertConfirmationMessage`: two hosts, one wording.
    public var discardConfirmationMessage: String {
        String(localized: "editor.discard.confirm.message", bundle: .module)
    }

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

        await unwindSessionEdits()
        // Only write if the unwind actually landed back where the session opened. It can fail to — an adopted
        // session's stack reaches back past this session's start — and half-unwound bytes are worse than the edits.
        guard !core.sessionHasEdits else { return }
        core.markDirtyForDiscardFlush()
        await flushPendingSave()
        await discardOriginalCapturedThisSession()
    }

    /// Walks this session's edits back to where it opened, migrates whatever the snapshot gear left owed, and
    /// publishes the result.
    ///
    /// Internal rather than private: the end-of-session tests drive it directly to assert what `sessionEndMode` says
    /// once a session has been unwound.
    ///
    /// The migration runs BEFORE the score is announced and the reload asked for, and the reload is asked for AFTER
    /// — deliberately. The host reads the restored score back out of the seam to answer "which staves does it author
    /// hidden?" for that reload, so telling it to reload first would have it reconcile a snapshot-numbered row
    /// against the intermediate-numbered score it was still holding, and write that mismatch back as provenance.
    func unwindSessionEdits() async {
        let revisionBefore = generation
        let owedMapping = core.unwindSessionEdits()
        var restoreMigration: [Int: Int?]?
        if let owedMapping, let session = core.session {
            restoreMigration = await migratePartIndexedState(owedMapping, in: session, for: core.scoreItem.id)
        }
        syncFromCore()
        // `syncFromCore` announces a score only when the revision moved past the host's copy, and an unwind that
        // lands back on an identical score still has to be drawn — the pages in between were not.
        if generation == revisionBefore, let score = core.score {
            onScoreChanged(score)
        }
        if owedMapping != nil {
            onPartIndicesRemapped(restoreMigration)
        }
    }

    /// Takes back the original this session's first save captured, now that those edits are gone: a score whose only
    /// edits were just thrown away must not go on offering to revert to an original it is already identical to.
    private func discardOriginalCapturedThisSession() async {
        guard let cleared = await core.discardOriginalCapturedThisSession() else { return }
        hasCapturedOriginal = false
        try? await repository.saveScoreItem(cleared)
    }
}
