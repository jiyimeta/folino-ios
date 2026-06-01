import Domain
import Foundation
@testable import ScoreFiles
import Testing

struct LiveScoreMetadataReaderTests {
    @Test func `reads museScore source from an on-disk mscz`() async throws {
        let tmp = try TempDirectory()
        defer { withExtendedLifetime(tmp) {} }
        let scores = tmp.url.appending(path: "Scores")
        try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
        let localFileName = "abc.mscz"
        try Fixtures.minimalMSCZData().write(to: scores.appending(path: localFileName))

        let reader = LiveScoreMetadataReader(
            gateway: LiveScoreFileGateway(),
            scoresDirectory: scores,
        )
        let item = ScoreItem(
            title: "T", composer: nil, instrumentationSummary: nil,
            localFileName: localFileName, contentHash: "h", sizeBytes: 1,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        let meta = try await reader.readMetadata(for: item)
        #expect(meta.source == .museScore(majorVersion: 4))
    }
}
