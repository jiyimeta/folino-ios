import Domain
import Foundation
import SheetMusicCore

/// Session lifecycle — entering and leaving edit mode. `beginSession(score:)` either adopts the history the previous
/// session deposited for this score or starts a fresh `ScoreEditSession`; `endSession()` flushes the pending save and
/// deposits the session for the next entry. Carved out of `EditorViewModel.swift` (which is at SwiftLint's
/// `file_length` budget) as a pure move — nothing here changed in the process.
extension EditorViewModel {
    public func beginSession(score: Score) {
        // A retained session is adopted as-is, and from that moment ITS score is the session's score — the `score:`
        // argument is dropped. The hash guard only proves the FILE has not changed since the deposit; it says
        // nothing about `parse(bytes) == session.score`, and the store is process-wide, so the two can legitimately
        // be different objects (✓ out of a score, close the Reader, reopen it from the Library: the Reader parses
        // from disk while this adopts the previous Reader's in-memory score). `onScoreChanged` below is what makes
        // the host definitionally show the adopted score rather than discover the difference at the first undo.
        //
        // A miss — nothing retained, or the file rewritten out-of-band since the deposit (revert, re-import,
        // version restore, PDF re-read) — starts fresh. `scoreItem.contentHash` is current here because the host
        // re-seeds the row (`refreshRow`) before every `beginSession` (`EditableReaderScreen.wireOnce()`).
        let adopted = historyStore.session(for: scoreItem.id, contentHash: scoreItem.contentHash)
        session = adopted ?? ScoreEditSession(score: score)
        // Both paths, because both need a way back: the fresh session's stack bottom would do, the adopted one's
        // would not (it is the PREVIOUS session's start), and `unwindSessionEdits()` must not have to tell them
        // apart.
        sessionOpenScore = session?.score
        generation = 0
        appliedEditCount = 0
        sessionEditDepth = 0
        didDiscardSession = false
        capturedOriginalThisSession = false
        // Fire-and-forget: the strip's revert offer is derived from the row, and the row can be behind what is
        // actually on disk. Nothing downstream waits on this — when it finds something, the control changes.
        Task { await reconcileCapturedOriginal() }
        selection = .none
        selectedItem = nil
        caretItem = nil
        armedDuration = nil
        armedDots = 0
        isAddToChordArmed = false
        // Only on the adopted path: a fresh session's score IS the argument the host just handed in, so telling it
        // about its own score would cost a re-layout for nothing.
        if let adopted {
            onScoreChanged(adopted.score)
        }
    }

    /// Flushes any pending autosave, deposits the session for the next entry on this score, and drops it.
    ///
    /// The ending session is captured up front and everything below acts on THAT object, never on a re-read of
    /// `self.session`. The caller is fire-and-forget (`EditableReaderScreen`: `Task { await vm.endSession() }`) and
    /// the flush is an unbounded await — a real gateway write plus a repository save — so a `beginSession` can
    /// legitimately land in that window. Re-reading `self.session` afterwards would deposit the NEW, live session
    /// into the store and then null it out, leaving a user who has just entered edit mode with a dead editor. The
    /// identity check before the teardown is the other half: only the session this call is ending may be cleared,
    /// which also makes a second `endSession()` a no-op rather than a second deposit. (The flush itself has to run
    /// BEFORE the teardown, not after the capture — `performSave()` writes `self.score`, which is the session's.)
    public func endSession() async {
        guard let ending = session else { return }
        await flushPendingSave()
        depositIfWorthKeeping(ending)
        guard session === ending else { return }
        session = nil
        sessionOpenScore = nil
    }

    /// Deposits the session — only when the flush left nothing unsaved (a failed final save discards the session,
    /// exactly today's failure contract: a retained history must describe bytes that are actually on disk) and the
    /// session has any history at all (an untouched session has nothing worth a slot). `scoreItem.contentHash` is
    /// the digest of exactly the bytes `session.score` was last saved as, because `flushPendingSave()` ran first.
    private func depositIfWorthKeeping(_ session: ScoreEditSession) {
        guard !didDiscardSession, !isDirty, session.canUndo || session.canRedo else { return }
        historyStore.retain(session, for: scoreItem.id, contentHash: scoreItem.contentHash)
    }
}
