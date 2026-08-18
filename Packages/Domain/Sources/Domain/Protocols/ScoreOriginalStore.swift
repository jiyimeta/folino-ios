import Foundation

/// Keeps and restores the bytes a score was imported with.
///
/// One seam for three callers that must not disagree: the Editor captures before its first write, the Reader
/// restores and reloads, and the score-info sheet restores from wherever it was opened. Everything that decides
/// *what* to do is a pure function in this module; an implementation of this protocol only performs it.
public protocol ScoreOriginalStore: Sendable {
    /// Copies (or adopts) the item's current file as its original, unless one is already recorded. Returns the item
    /// to persist — unchanged when nothing was captured. Never throws for a missing file: an item whose bytes are
    /// gone has bigger problems than a missing original, and failing here would block the save that follows.
    func captureOriginalIfNeeded(for item: ScoreItem) async throws -> ScoreItem

    /// Writes the original's bytes back over the item's file and returns the row that describes the result. Content
    /// -derived fields always come from a fresh parse of those bytes; the credit fields do only when
    /// `restoringScoreInfo` is true.
    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) async throws -> ScoreItem

    /// Forgets the recorded original, deleting the sidecar if the original is one. For a re-read, which replaces the
    /// notation the original was the baseline of.
    func discardOriginal(for item: ScoreItem) async throws -> ScoreItem

    /// Registers an original that is already on disk but missing from the row, and returns the item to persist —
    /// unchanged when there is nothing to adopt. **Copies nothing**, so it is safe to call on a score that has never
    /// been edited: with no file there, there is nothing to find.
    ///
    /// This exists because a capture is three steps — copy the sidecar, write the score, update the row — and only
    /// the first two are on the path that must complete. Kill the app between the write and the row update and the
    /// edit survives while the row forgets its original; the sidecar is sitting right there, and until something
    /// looks for it the score offers no way back. `captureOriginalIfNeeded` already re-adopts in that situation, but
    /// only during the *next* save, which may never come. Reconciling when a session opens closes that window.
    ///
    /// The sidecar's existence is the marker — the same rule `captureOriginalIfNeeded` follows for the same reason.
    func adoptOrphanedOriginal(for item: ScoreItem) async -> ScoreItem
}

extension ScoreOriginalStore {
    /// Nothing to reconcile, for stores with no disk behind them (previews, fixtures, the no-op).
    public func adoptOrphanedOriginal(for item: ScoreItem) -> ScoreItem {
        item
    }
}
