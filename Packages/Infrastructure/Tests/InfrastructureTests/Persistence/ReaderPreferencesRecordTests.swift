import Domain
import GRDB
@testable import Persistence
import Testing

@Suite struct ReaderPreferencesRecordTests {
    @Test func roundTripsThroughDomain() throws {
        let scoreID = ScoreItemID()
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, staffSize: 12, hiddenStaffIDs: [0, 2]
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored == prefs)
    }

    @Test func encodesAndDecodesViaSQLite() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.all.migrate(queue)
        // The FK requires a parent score row to exist before insert.
        let scoreID = ScoreItemID()
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO score_items (id, title, local_file_name, content_hash,
                    size_bytes, length_beats, default_tempo_bpm, added_at)
                VALUES (?, 'T', 'f.mscx', 'h', 0, 0, 120, 0)
                """,
                arguments: [scoreID.rawValue.uuidString]
            )
        }
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, staffSize: 16, hiddenStaffIDs: [3]
        )
        try queue.write { try ReaderPreferencesRecord(domain: prefs).save($0) }
        let fetched = try queue.read {
            try ReaderPreferencesRecord
                .filter(Column("score_item_id") == scoreID.rawValue.uuidString)
                .fetchOne($0)
        }
        let unwrapped = try #require(fetched)
        let restored = try unwrapped.toDomain()
        #expect(restored.staffSize == 16)
        #expect(restored.hiddenStaffIDs == [3])
    }

    @Test func emptyHiddenSetEncodesAsEmptyJSON() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaffIDs: []
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        #expect(record.hiddenStaffIds == "[]")
    }
}
