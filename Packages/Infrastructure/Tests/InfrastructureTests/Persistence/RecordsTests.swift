@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

struct RecordsTests {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppMigrations.v1.migrate(q)
        return q
    }

    @Test func `tag round trips`() throws {
        let queue = try makeQueue()
        let tag = Domain.Tag(name: "Bach", colorHex: "#AA00FF")
        try queue.write { db in try TagRecord(domain: tag).insert(db) }
        let fetched = try queue.read { db in
            try TagRecord.fetchOne(db, key: tag.id.rawValue.uuidString)
        }
        let domain = try #require(fetched).toDomain()
        #expect(domain == tag)
    }

    @Test func `playlist round trips without items`() throws {
        let queue = try makeQueue()
        let playlist = Playlist(
            name: "Practice", orderedScoreItemIDs: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
        try queue.write { db in try PlaylistRecord(domain: playlist).insert(db) }
        let fetched = try queue.read { db in
            try PlaylistRecord.fetchOne(db, key: playlist.id.rawValue.uuidString)
        }
        let domain = try #require(fetched).toDomain(orderedScoreItemIDs: [])
        #expect(domain == playlist)
    }

    @Test func `playlist item position round trips`() throws {
        let queue = try makeQueue()
        let pl = Playlist(name: "x", orderedScoreItemIDs: [], createdAt: Date())
        let scoreA = ScoreItem(
            title: "a", composer: nil, instrumentationSummary: nil,
            localFileName: "a.mid", contentHash: "h1", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        let scoreB = ScoreItem(
            title: "b", composer: nil, instrumentationSummary: nil,
            localFileName: "b.mid", contentHash: "h2", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        try queue.write { db in
            try PlaylistRecord(domain: pl).insert(db)
            try ScoreItemRecord(domain: scoreA).insert(db)
            try ScoreItemRecord(domain: scoreB).insert(db)
            try PlaylistItemRecord(
                playlistID: pl.id.rawValue.uuidString,
                scoreItemID: scoreB.id.rawValue.uuidString,
                position: 1,
            ).insert(db)
            try PlaylistItemRecord(
                playlistID: pl.id.rawValue.uuidString,
                scoreItemID: scoreA.id.rawValue.uuidString,
                position: 0,
            ).insert(db)
        }

        let ordered = try queue.read { db -> [String] in
            try PlaylistItemRecord
                .filter(Column("playlist_id") == pl.id.rawValue.uuidString)
                .order(Column("position"))
                .fetchAll(db)
                .map(\.scoreItemID)
        }
        #expect(ordered == [scoreA.id.rawValue.uuidString, scoreB.id.rawValue.uuidString])
    }

    @Test func `tag delete cascades to junction`() throws {
        let queue = try makeQueue()
        let tag = Domain.Tag(name: "x", colorHex: "#000000")
        let item = ScoreItem(
            title: "i", composer: nil, instrumentationSummary: nil,
            localFileName: "i.mid", contentHash: "h", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [tag.id], isFavorite: false,
        )
        try queue.write { db in
            try TagRecord(domain: tag).insert(db)
            try ScoreItemRecord(domain: item).insert(db)
            try ScoreItemTagRecord(
                scoreItemID: item.id.rawValue.uuidString,
                tagID: tag.id.rawValue.uuidString,
            ).insert(db)
        }
        try queue.write { db in
            _ = try TagRecord.deleteOne(db, key: tag.id.rawValue.uuidString)
        }
        let remaining = try queue.read { db in
            try ScoreItemTagRecord
                .filter(Column("score_item_id") == item.id.rawValue.uuidString)
                .fetchCount(db)
        }
        #expect(remaining == 0)
    }
}
