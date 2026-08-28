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
    func session(for id: ScoreItemID, contentHash: String) -> ScoreEditSession?
    /// Deposits `session` as the most-recent entry, evicting least-recently-used entries over the cap.
    func retain(_ session: ScoreEditSession, for id: ScoreItemID, contentHash: String)
    /// Drops any retained session for `id`.
    func invalidate(_ id: ScoreItemID)
}
