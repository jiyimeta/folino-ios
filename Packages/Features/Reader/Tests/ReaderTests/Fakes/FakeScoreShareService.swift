import Domain
import Foundation

final class FakeScoreShareService: ScoreShareService, @unchecked Sendable {
    var preparedURL = URL(filePath: "/tmp/shared.mscz")
    var formats: [ScoreShareFormatOption] = [ScoreShareFormatOption(format: .museScoreV4, isOriginal: true)]
    private(set) var prepareCallCount = 0

    func availableFormats(for _: ScoreItem) -> [ScoreShareFormatOption] {
        formats
    }

    func prepareShare(item _: ScoreItem, format _: ScoreShareFormat) throws -> URL {
        prepareCallCount += 1
        return preparedURL
    }
}
