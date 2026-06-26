@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

struct ScoreItemRecordTests {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        // Record mirrors the latest schema (incl. `deleted_at` from v8) so we need the full migrator here.
        try AppMigrations.all.migrate(q)
        return q
    }

    private func sampleItem() -> ScoreItem {
        ScoreItem(
            title: "Prelude in C",
            composer: "Bach",
            instrumentationSummary: "Piano",
            localFileName: "x.mscz",
            contentHash: String(repeating: "a", count: 64),
            sizeBytes: 4096,
            lengthBeats: 32,
            defaultTempoBpm: 80,
            primaryKey: "C",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: true,
        )
    }

    @Test func `round trips through GRDB`() throws {
        let queue = try makeQueue()
        let item = sampleItem()
        try queue.write { db in
            try ScoreItemRecord(domain: item).insert(db)
        }
        let fetched = try queue.read { db -> ScoreItemRecord? in
            try ScoreItemRecord.fetchOne(db, key: item.id.rawValue.uuidString)
        }
        let domain = try #require(fetched).toDomain(tagIDs: [])
        #expect(domain == item)
    }

    @Test func `record round-trips credit fields`() throws {
        let item = ScoreItem(
            title: "T",
            composer: "C",
            arranger: "A",
            lyricist: "L",
            copyright: "©",
            instrumentationSummary: nil,
            localFileName: "x.mscx",
            contentHash: "h",
            sizeBytes: 1,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        let record = ScoreItemRecord(domain: item)
        let back = try record.toDomain(tagIDs: [])
        #expect(back.arranger == "A")
        #expect(back.lyricist == "L")
        #expect(back.copyright == "©")
    }

    @Test func `round-trips museScoreMajorVersion through database`() throws {
        let queue = try makeQueue()
        var item = sampleItem()
        item.museScoreMajorVersion = 3
        try queue.write { db in
            try ScoreItemRecord(domain: item).insert(db)
        }
        let fetched = try queue.read { db -> ScoreItemRecord? in
            try ScoreItemRecord.fetchOne(db, key: item.id.rawValue.uuidString)
        }
        let domain = try #require(fetched).toDomain(tagIDs: [])
        #expect(domain.museScoreMajorVersion == 3)
    }

    @Test func `museScoreMajorVersion is nil for non-MuseScore items`() throws {
        let queue = try makeQueue()
        let item = sampleItem()
        // sampleItem has no museScoreMajorVersion set, so it defaults to nil.
        try queue.write { db in
            try ScoreItemRecord(domain: item).insert(db)
        }
        let fetched = try queue.read { db -> ScoreItemRecord? in
            try ScoreItemRecord.fetchOne(db, key: item.id.rawValue.uuidString)
        }
        let domain = try #require(fetched).toDomain(tagIDs: [])
        #expect(domain.museScoreMajorVersion == nil)
    }
}
