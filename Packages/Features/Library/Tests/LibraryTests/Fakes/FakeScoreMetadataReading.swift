import Domain
import Foundation

final class FakeScoreMetadataReading: ScoreMetadataReading, @unchecked Sendable {
    var result: Result<ScoreFileMetadata, DomainError> = .success(
        ScoreFileMetadata(source: .unknown, composer: nil, arranger: nil, lyricist: nil, copyright: nil),
    )

    func readMetadata(for item: ScoreItem) throws -> ScoreFileMetadata {
        switch result {
        case let .success(meta): return meta
        case let .failure(error): throw error
        }
    }
}
