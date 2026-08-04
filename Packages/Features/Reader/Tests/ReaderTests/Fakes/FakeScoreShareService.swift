import Domain
import Foundation

final class FakeScoreShareService: ScoreShareService, @unchecked Sendable {
    var preparedURL = URL(filePath: "/tmp/shared.mscz")
    var formats: [ScoreShareFormatOption] = [ScoreShareFormatOption(format: .museScoreV4, isOriginal: true)]
    var prepareError: DomainError?
    private(set) var prepareCallCount = 0
    private(set) var requestedFormats: [ScoreShareFormat] = []

    func availableFormats(for _: ScoreItem) -> [ScoreShareFormatOption] {
        formats
    }

    func prepareShare(item _: ScoreItem, format: ScoreShareFormat) throws -> URL {
        prepareCallCount += 1
        requestedFormats.append(format)
        if let prepareError { throw prepareError }
        return preparedURL
    }
}
