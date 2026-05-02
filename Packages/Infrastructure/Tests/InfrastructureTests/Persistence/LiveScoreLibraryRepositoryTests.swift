@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@MainActor
@Suite struct LiveScoreLibraryRepositoryTests {
    private func makeDatabase() throws -> AppDatabase {
        let tmp = try TempDirectory()
        return try AppDatabase(databaseURL: tmp.url.appending(path: "f.sqlite"))
    }

    @Test func refreshOnEmptyDatabaseProducesEmptyArrays() async throws {
        let db = try makeDatabase()
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()
        #expect(repo.scoreItems.isEmpty)
        #expect(repo.tags.isEmpty)
        #expect(repo.playlists.isEmpty)
    }
}
