import Domain
import Foundation
@testable import ScoreFiles
import Testing

struct LiveScoreFileGatewayPDFTests {
    private func fixtureURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "sample", withExtension: "pdf"))
    }

    @Test func `load file metadata returns PDF summary`() async throws {
        let gateway = LiveScoreFileGateway()
        let summary = try await gateway.loadFileMetadata(fileURL: fixtureURL())
        #expect(summary.title == "Sample Title")
        #expect(summary.lengthBeats == 0)
        #expect(summary.defaultTempoBpm == 0)
        #expect(summary.instrumentationSummary.isEmpty)
    }

    @Test func `load score rejects PDF`() async throws {
        let gateway = LiveScoreFileGateway()
        let url = try fixtureURL()
        await #expect(throws: DomainError.self) {
            _ = try await gateway.loadScore(fileURL: url)
        }
    }
}
