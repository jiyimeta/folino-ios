import Domain
import Foundation

/// Does nothing, for previews. A preview session never outlives its view, so it has no history to keep.
@MainActor
final class NoopScoreEditHistoryStore: ScoreEditHistoryStore {
    func session(for _: ScoreItemID, contentHash _: String) -> ScoreEditSession? {
        nil
    }

    func retain(_: ScoreEditSession, for _: ScoreItemID, contentHash _: String) {}

    func invalidate(_: ScoreItemID) {}
}
