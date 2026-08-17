import Domain
import Foundation

final class FakeScoreOriginalStore: ScoreOriginalStore, @unchecked Sendable {
    var captureCalls: [ScoreItem] = []
    var revertCalls: [(ScoreItem, Bool)] = []
    var discardCalls: [ScoreItem] = []
    /// When set, `revertToOriginal` throws this instead of succeeding — exercises the failure path.
    var revertError: Error?

    func captureOriginalIfNeeded(for item: ScoreItem) throws -> ScoreItem {
        captureCalls.append(item)
        return item
    }

    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) throws -> ScoreItem {
        revertCalls.append((item, restoringScoreInfo))
        if let revertError { throw revertError }
        var cleared = item
        cleared.originalFileName = nil
        cleared.originalContentHash = nil
        cleared.originalProvenance = nil
        return cleared
    }

    func discardOriginal(for item: ScoreItem) throws -> ScoreItem {
        discardCalls.append(item)
        return item
    }
}
