import Domain
import Foundation

/// Reading an existing score back so the creation wizard can clone its instrumentation. Split out of
/// `LibraryViewModel.swift` for the same reason `+Share` and `+Revert` are — one flow per file. `createScore(from:)`
/// stays in the main file: it writes `pendingOpenInEditSession`, whose `private(set)` setter no extension can reach.
extension LibraryViewModel {
    /// Parses `item`'s file so the creation wizard can clone its instrumentation, or `nil` when the file cannot be
    /// read. `ScoreFileGateway.loadScore` is `async` and its live implementation runs off the main actor, so the
    /// parse never blocks the sheet.
    ///
    /// A failure lands on `currentError` — the same channel `NewScoreSheet`'s own alert presents, since the sheet
    /// is on screen while this runs — and is recorded, matching `createScore(from:)`.
    func instrumentation(of item: ScoreItem) async -> Score? {
        do {
            let (score, _) = try await gateway.loadScore(
                fileURL: scoresDirectory.appending(path: item.localFileName),
            )
            return score
        } catch {
            crashReporter.record(error: error)
            currentError = error
            return nil
        }
    }
}
