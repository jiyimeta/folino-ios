import Domain
import Foundation

final class FakeScoreShareService: ScoreShareService, @unchecked Sendable {
    var availableFormatsByDefault: [ScoreShareFormatOption] = [
        ScoreShareFormatOption(format: .museScoreV4, isOriginal: true),
        ScoreShareFormatOption(format: .museScoreV3),
        ScoreShareFormatOption(format: .pdf),
        ScoreShareFormatOption(format: .midi),
        ScoreShareFormatOption(format: .audioM4A),
    ]

    var prepareShareError: DomainError?
    var prepareShareReturnURL: URL = .init(fileURLWithPath: "/tmp/share-fake")
    private(set) var prepareShareCalls: [(item: ScoreItem, format: ScoreShareFormat)] = []

    /// Tests set this to make `prepareShare` await the closure mid-flight, so they can observe `vm.isPreparingShare ==
    /// true` while the call is in flight.
    var inFlightHook: (@Sendable () async -> Void)?

    func availableFormats(for _: ScoreItem) -> [ScoreShareFormatOption] {
        availableFormatsByDefault
    }

    func prepareShare(item: ScoreItem, format: ScoreShareFormat) async throws -> URL {
        prepareShareCalls.append((item, format))
        if let hook = inFlightHook { await hook() }
        if let error = prepareShareError { throw error }
        return prepareShareReturnURL
    }
}
