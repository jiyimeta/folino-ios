import Domain
import Foundation

/// Does nothing, for previews. A preview session never outlives its view, so it has no history to keep.
@MainActor
final class NoopScoreEditHistoryStore: ScoreEditHistoryStore {
    func session(for _: ScoreItemID, contentHash _: String) -> RetainedEditSession? {
        nil
    }

    func retain(_: RetainedEditSession, for _: ScoreItemID, contentHash _: String) {}

    func invalidate(_: ScoreItemID) {}
}
