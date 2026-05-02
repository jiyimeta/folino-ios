@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@MainActor
@Suite struct LiveScoreLibraryRepositoryTests {
    /// Returns a database AND a lifetime anchor that keeps the temp directory
    /// alive for the duration of the test. Both must be retained together.
    private func makeDatabase() throws -> (AppDatabase, TempDirectory) {
        let tmp = try TempDirectory()
        let db = try AppDatabase(databaseURL: tmp.url.appending(path: "f.sqlite"))
        return (db, tmp)
    }

    @Test func refreshOnEmptyDatabaseProducesEmptyArrays() async throws {
        let (db, lifetime) = try makeDatabase()
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()
        #expect(repo.scoreItems.isEmpty)
        #expect(repo.tags.isEmpty)
        #expect(repo.playlists.isEmpty)
        withExtendedLifetime(lifetime) {}
    }

    @Test func saveScoreItemRoundTripsViaObservation() async throws {
        let (db, lifetime) = try makeDatabase()
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        let tag = Domain.Tag(name: "Bach", colorHex: "#FF0000")
        try await db.pool.write { try TagRecord(domain: tag).insert($0) }

        let item = ScoreItem(
            title: "Prelude", composer: "Bach", instrumentationSummary: "Piano",
            localFileName: "x.mscz", contentHash: "h1", sizeBytes: 100,
            lengthBeats: 16, defaultTempoBpm: 80, primaryKey: "C",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [tag.id], isFavorite: false
        )
        try await repo.saveScoreItem(item)

        try await waitFor { repo.scoreItems.contains { $0.id == item.id } }
        let stored = try #require(repo.scoreItems.first { $0.id == item.id })
        #expect(stored.tagIDs == [tag.id])
        #expect(stored.title == "Prelude")
        withExtendedLifetime(lifetime) {}
    }

    @Test func deleteScoreItemRemovesFromArray() async throws {
        let (db, lifetime) = try makeDatabase()
        let scoresDir = try TempDirectory()
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: scoresDir.url)
        try await repo.refresh()

        let item = ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            localFileName: "x.mid", contentHash: "h", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
        try await repo.saveScoreItem(item)
        try await waitFor { repo.scoreItems.contains { $0.id == item.id } }

        try await repo.deleteScoreItem(id: item.id)
        try await waitFor { !repo.scoreItems.contains { $0.id == item.id } }
        withExtendedLifetime(lifetime) {}
    }

    /// Polls a predicate up to ~2s, yielding to the runtime between checks so
    /// the ValueObservation task can run.
    @MainActor
    private func waitFor(
        timeout: Duration = .seconds(2),
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("predicate never satisfied within \(timeout)")
    }
}
