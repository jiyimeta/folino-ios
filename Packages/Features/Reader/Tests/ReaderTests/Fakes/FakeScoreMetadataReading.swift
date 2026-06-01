import Domain
import Foundation

final class FakeScoreMetadataReading: ScoreMetadataReading, @unchecked Sendable {
    var metadata = ScoreFileMetadata(
        source: .museScore(majorVersion: 4),
        composer: "File Composer", arranger: nil, lyricist: nil, copyright: nil,
    )

    func readMetadata(for _: ScoreItem) throws -> ScoreFileMetadata {
        metadata
    }
}
