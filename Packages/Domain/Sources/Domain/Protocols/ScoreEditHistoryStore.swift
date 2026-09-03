import Foundation

/// Retains edit sessions across Editor entries, for the process lifetime. Memory-only by design: killing the app
/// drops every history, and so does memory pressure — there is no disk, no version history, no sync.
///
/// `@MainActor` with synchronous methods, not `Sendable`-async like `ScoreOriginalStore`: `ScoreEditSession` is
/// deliberately not `Sendable` ("hold one per isolation domain"), so the store must live on the actor that drives
/// sessions — the main actor, where `EditorViewModel` already is.
///
/// `session(for:contentHash:)` CHECKS THE ENTRY OUT — the returned session has one owner (the view model) until
/// `retain` deposits it again. That keeps LRU accounting trivial and makes an iPad split-view double-open of one
/// score safe: the second session finds nothing and starts fresh.
@MainActor
public protocol ScoreEditHistoryStore: AnyObject {
    /// Removes and returns the retained session for `id` — or nil (and drops any stale entry) when none is
    /// retained or `contentHash` differs from what it was deposited with.
    func session(for id: ScoreItemID, contentHash: String) -> RetainedEditSession?
    /// Deposits `retained` as the most-recent entry, evicting least-recently-used entries over the cap.
    func retain(_ retained: RetainedEditSession, for id: ScoreItemID, contentHash: String)
    /// Drops any retained session for `id`.
    func invalidate(_ id: ScoreItemID)
}

/// A session kept between entries, together with how many steps its undo stack holds.
///
/// The count travels with the session because `ScoreEditSession` does not publish one — it answers `canUndo`, not
/// "how deep". A host that has to arm something PER undoable step (macOS registers one `UndoManager` trampoline
/// each, since there is no undo button in that window) cannot ask the session and cannot count without undoing, so
/// the depth is tallied while the edits are being made and deposited alongside the session that carries them.
public struct RetainedEditSession {
    public let session: ScoreEditSession
    /// How many steps the session's undo stack holds at the moment of the deposit. Never negative.
    public let undoableStepCount: Int

    public init(session: ScoreEditSession, undoableStepCount: Int) {
        self.session = session
        self.undoableStepCount = undoableStepCount
    }
}
