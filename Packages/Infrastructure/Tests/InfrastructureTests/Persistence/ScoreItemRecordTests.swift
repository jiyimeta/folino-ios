@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite struct ScoreItemRecordTests {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppMigrations.v1.migrate(q)
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
            isFavorite: true
        )
    }

    @Test func roundTripsThroughGRDB() throws {
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
}
