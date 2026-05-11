@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@MainActor
struct LiveScoreLibraryRepositoryTests {
    /// Returns a database AND a lifetime anchor that keeps the temp directory
    /// alive for the duration of the test. Both must be retained together.
    private func makeDatabase() throws -> (AppDatabase, TempDirectory) {
        let tmp = try TempDirectory()
        let db = try AppDatabase(databaseURL: tmp.url.appending(path: "f.sqlite"))
        return (db, tmp)
    }

    @Test func `refresh on empty database produces empty arrays`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()
        #expect(repo.scoreItems.isEmpty)
        #expect(repo.tags.isEmpty)
        #expect(repo.playlists.isEmpty)
    }

    @Test func `save score item round trips via observation`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        let tag = Domain.Tag(name: "Bach", colorHex: "#FF0000")
        try await db.pool.write { try TagRecord(domain: tag).insert($0) }

        let item = ScoreItem(
            title: "Prelude", composer: "Bach", instrumentationSummary: "Piano",
            localFileName: "x.mscz", contentHash: "h1", sizeBytes: 100,
            lengthBeats: 16, defaultTempoBpm: 80, primaryKey: "C",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [tag.id], isFavorite: false,
        )
        try await repo.saveScoreItem(item)

        try await waitFor { repo.scoreItems.contains { $0.id == item.id } }
        let stored = try #require(repo.scoreItems.first { $0.id == item.id })
        #expect(stored.tagIDs == [tag.id])
        #expect(stored.title == "Prelude")
    }

    @Test func `delete score item removes from array`() async throws {
        let (db, lifetime) = try makeDatabase()
        let scoresDir = try TempDirectory()
        defer { withExtendedLifetime((lifetime, scoresDir)) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: scoresDir.url)
        try await repo.refresh()

        let item = ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            localFileName: "x.mid", contentHash: "h", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        try await repo.saveScoreItem(item)
        try await waitFor { repo.scoreItems.contains { $0.id == item.id } }

        try await repo.deleteScoreItem(id: item.id)
        try await waitFor { !repo.scoreItems.contains { $0.id == item.id } }
    }

    @Test func `save tag appears in observed array`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        let tag = Domain.Tag(name: "Romantic", colorHex: "#00FFAA")
        try await repo.saveTag(tag)
        try await waitFor { repo.tags.contains { $0.id == tag.id } }
    }

    @Test func `delete tag cascades to item tag I ds`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        let tag = Domain.Tag(name: "x", colorHex: "#000000")
        try await repo.saveTag(tag)
        let item = ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            localFileName: "x.mid", contentHash: "h", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [tag.id], isFavorite: false,
        )
        try await repo.saveScoreItem(item)
        try await waitFor { repo.scoreItems.first { $0.id == item.id }?.tagIDs == [tag.id] }

        try await repo.deleteTag(id: tag.id)
        try await waitFor { repo.scoreItems.first { $0.id == item.id }?.tagIDs.isEmpty == true }
    }

    @Test func `content hash lookup returns all matches`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        let h = "shared-hash"
        func make() -> ScoreItem {
            ScoreItem(
                title: "x", composer: nil, instrumentationSummary: nil,
                localFileName: "\(UUID().uuidString).mid", contentHash: h, sizeBytes: 0,
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
                addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
            )
        }
        try await repo.saveScoreItem(make())
        try await repo.saveScoreItem(make())
        let unique = make()
        let renamed = ScoreItem(
            id: unique.id, title: unique.title, composer: nil,
            instrumentationSummary: nil, localFileName: unique.localFileName,
            contentHash: "different", sizeBytes: 0, lengthBeats: 0,
            defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        try await repo.saveScoreItem(renamed)

        let dups = try await repo.scoreItems(matchingContentHash: h)
        #expect(dups.count == 2)
    }

    @Test func `playlist ordering round trips through observation`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        func make() -> ScoreItem {
            ScoreItem(
                title: "x", composer: nil, instrumentationSummary: nil,
                localFileName: "\(UUID().uuidString).mid", contentHash: "h", sizeBytes: 0,
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
                addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
            )
        }
        let a = make(); let b = make(); let c = make()
        try await repo.saveScoreItem(a)
        try await repo.saveScoreItem(b)
        try await repo.saveScoreItem(c)
        try await waitFor { repo.scoreItems.count == 3 }

        let pl = Playlist(
            name: "Practice",
            orderedScoreItemIDs: [c.id, a.id, b.id],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        try await repo.savePlaylist(pl)
        try await waitFor {
            repo.playlists.first?.orderedScoreItemIDs == [c.id, a.id, b.id]
        }
        #expect(repo.playlists.count == 1)
    }

    @Test func `delete playlist removes it`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()

        let pl = Playlist(name: "x", orderedScoreItemIDs: [], createdAt: Date())
        try await repo.savePlaylist(pl)
        try await waitFor { repo.playlists.contains { $0.id == pl.id } }
        try await repo.deletePlaylist(id: pl.id)
        try await waitFor { !repo.playlists.contains { $0.id == pl.id } }
    }

    // MARK: - Reader preferences

    @Test func `load reader preferences returns nil when absent`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        let result = try await repo.loadReaderPreferences(for: ScoreItemID())
        #expect(result == nil)
    }

    @Test func `save then load round trips reader preferences`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        let item = ScoreItem(
            title: "Prelude", composer: "Bach", instrumentationSummary: "Piano",
            localFileName: "x.mscz", contentHash: "h1", sizeBytes: 100,
            lengthBeats: 16, defaultTempoBpm: 80, primaryKey: "C",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        try await repo.refresh()
        try await repo.saveScoreItem(item)

        let hidden: Set<StaffAddress> = [
            StaffAddress(partIndex: 0, staffIndexInPart: 1),
            StaffAddress(partIndex: 2, staffIndexInPart: 0),
        ]
        let prefs = ReaderPreferences(
            scoreItemID: item.id, staffSize: 18, hiddenStaves: hidden,
        )
        try await repo.saveReaderPreferences(prefs)

        let loaded = try await repo.loadReaderPreferences(for: item.id)
        #expect(loaded?.staffSize == 18)
        #expect(loaded?.hiddenStaves == hidden)
        #expect(loaded?.scoreItemID == item.id)
    }

    @Test func `save reader preferences upserts existing`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        let item = ScoreItem(
            title: "Prelude", composer: "Bach", instrumentationSummary: "Piano",
            localFileName: "x.mscz", contentHash: "h1", sizeBytes: 100,
            lengthBeats: 16, defaultTempoBpm: 80, primaryKey: "C",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        try await repo.refresh()
        try await repo.saveScoreItem(item)

        let first = ReaderPreferences(
            scoreItemID: item.id, staffSize: 14, hiddenStaves: [],
        )
        try await repo.saveReaderPreferences(first)

        var second = first
        second.staffSize = 20
        second.hiddenStaves = [StaffAddress(partIndex: 1, staffIndexInPart: 0)]
        try await repo.saveReaderPreferences(second)

        let loaded = try await repo.loadReaderPreferences(for: item.id)
        #expect(loaded?.staffSize == 20)
        #expect(loaded?.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 0)])
    }
}
