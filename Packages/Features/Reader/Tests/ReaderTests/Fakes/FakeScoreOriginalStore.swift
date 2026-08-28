import Domain
import Foundation

final class FakeScoreOriginalStore: ScoreOriginalStore, @unchecked Sendable {
    var discardCalls: [ScoreItem] = []

    func captureOriginalIfNeeded(for item: ScoreItem) -> ScoreItem {
        item
    }

    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo _: Bool) -> ScoreItem {
        item
    }

    func discardOriginal(for item: ScoreItem) -> ScoreItem {
        discardCalls.append(item)
        var cleared = item
        cleared.originalFileName = nil
        cleared.originalContentHash = nil
        cleared.originalProvenance = nil
        return cleared
    }
}
