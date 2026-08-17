import Domain
import Foundation

/// Does nothing, for previews. A preview never writes, so it never needs an original.
struct NoopScoreOriginalStore: ScoreOriginalStore {
    // swiftlint:disable:next async_without_await
    func captureOriginalIfNeeded(for item: ScoreItem) async throws -> ScoreItem {
        item
    }

    // swiftlint:disable:next async_without_await
    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo _: Bool) async throws -> ScoreItem {
        item
    }

    // swiftlint:disable:next async_without_await
    func discardOriginal(for item: ScoreItem) async throws -> ScoreItem {
        item
    }
}
