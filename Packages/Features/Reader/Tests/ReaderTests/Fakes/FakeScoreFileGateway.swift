import Domain
import Foundation

final class FakeScoreFileGateway: ScoreFileGateway, @unchecked Sendable {
    var loadScoreResult: Result<(score: Score, summary: ScoreFileSummary), DomainError>

    init(loadScoreResult: Result<(score: Score, summary: ScoreFileSummary), DomainError> =
        .success((
            score: Score(division: 480, parts: [], staves: [], metaTags: [:]),
            summary: ScoreFileSummary(
                title: "Test", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
        )))
    {
        self.loadScoreResult = loadScoreResult
    }

    func detectFormat(fileName: String) -> ScoreFormat? { .mscx }

    func loadFileMetadata(fileURL: URL) throws -> ScoreFileSummary {
        throw DomainError.unsupportedFormat("test")
    }

    func loadScore(fileURL: URL) throws -> (score: Score, summary: ScoreFileSummary) {
        switch loadScoreResult {
        case let .success(value): return value
        case let .failure(error): throw error
        }
    }

    func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) throws {
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }
}
