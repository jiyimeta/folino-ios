import Domain
import Foundation

final class FakeScoreFileCreator: ScoreFileCreator, @unchecked Sendable {
    var createdScores: [Score] = []
    var result: Result<ScoreItem, Error> = .failure(DomainError.persistenceFailed(
        reason: "FakeScoreFileCreator not configured",
    ))

    func createScore(_ score: Score) throws -> ScoreItem {
        createdScores.append(score)
        return try result.get()
    }
}
