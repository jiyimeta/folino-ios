import Domain
import Foundation

final class FakeScoreFileGateway: ScoreFileGateway, @unchecked Sendable {
    var detectedFormat: ScoreFormat? = .mscx
    var loadFileMetadataResult: Result<ScoreFileSummary, DomainError> =
        .success(ScoreFileSummary(
            title: "Untitled", composer: nil, instrumentationSummary: "",
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
        ))
    var loadScoreError: DomainError?

    func detectFormat(fileName: String) -> ScoreFormat? {
        detectedFormat
    }

    func loadFileMetadata(fileURL: URL) throws -> ScoreFileSummary {
        switch loadFileMetadataResult {
        case let .success(summary): summary
        case let .failure(error): throw error
        }
    }

    func loadScore(fileURL: URL) throws -> (score: Score, summary: ScoreFileSummary) {
        if let error = loadScoreError { throw error }
        // Library tests do not exercise loaded Scores; provide an empty stub.
        // ScoreFileGateway is async but the fake satisfies both sync and async
        // shapes. Real Score values are exercised by Reader tests via a
        // separate fake (Task 20).
        throw DomainError.scoreParseFailed(reason: "FakeScoreFileGateway.loadScore stubbed")
    }

    func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) throws {
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }
}
