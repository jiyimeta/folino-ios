import Domain
import Foundation
import GRDB
@testable import Persistence
import SheetMusicCore
import Testing

@Suite struct ReaderPreferencesRecordTests {
    @Test func roundTripsThroughDomain() throws {
        let scoreID = ScoreItemID()
        let prefs = ReaderPreferences(
            scoreItemID: scoreID,
            staffSize: 12,
            hiddenStaves: [
                StaffAddress(partIndex: 0, staffIndexInPart: 0),
                StaffAddress(partIndex: 1, staffIndexInPart: 1),
            ]
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
        let hidden: Set<StaffAddress> = [StaffAddress(partIndex: 1, staffIndexInPart: 0)]
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, staffSize: 16, hiddenStaves: hidden
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
        #expect(restored.hiddenStaves == hidden)
    }

    @Test func emptyHiddenSetEncodesAsEmptyJSON() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: []
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        #expect(record.hiddenStaffIds == "[]")
    }

    @Test func emptyProgramOverridesEncodesAsEmptyJSON() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: []
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        #expect(record.staffProgramOverrides == "[]")
    }

    @Test func programOverridesRoundTripThroughDomain() throws {
        let address1 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let address2 = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffProgramOverrides: [address1: 6, address2: 40]
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.staffProgramOverrides == [address1: 6, address2: 40])
    }

    @Test func honorLayoutBreaksRoundTripsThroughDomain() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            honorLayoutBreaks: false
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.honorLayoutBreaks == false)
    }

    @Test func honorLayoutBreaksDefaultsToTrueOnDomainConstruction() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: []
        )
        #expect(prefs.honorLayoutBreaks == true)
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.honorLayoutBreaks == true)
    }

    @Test func emptyVolumeOverridesEncodesAsEmptyJSON() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: []
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        #expect(record.staffVolumeOverrides == "[]")
    }

    @Test func volumeOverridesRoundTripThroughDomain() throws {
        let address1 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let address2 = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffVolumeOverrides: [address1: 0.25, address2: 0.75]
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.staffVolumeOverrides == [address1: 0.25, address2: 0.75])
    }

    @Test func emptyClefOverridesEncodesAsEmptyJSON() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: []
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        #expect(record.staffClefOverrides == "[]")
    }

    @Test func clefOverridesRoundTripThroughDomain() throws {
        let address1 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let address2 = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffClefOverrides: [address1: "G8vb", address2: "F"]
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.staffClefOverrides == [address1: "G8vb", address2: "F"])
    }

    @Test func clefOverridesPersistThroughSQLite() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.all.migrate(queue)
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
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        let prefs = ReaderPreferences(
            scoreItemID: scoreID,
            staffSize: 14,
            hiddenStaves: [],
            staffClefOverrides: [address: "G8vb"]
        )
        try queue.write { try ReaderPreferencesRecord(domain: prefs).save($0) }
        let fetched = try queue.read {
            try ReaderPreferencesRecord
                .filter(Column("score_item_id") == scoreID.rawValue.uuidString)
                .fetchOne($0)
        }
        let unwrapped = try #require(fetched)
        let restored = try unwrapped.toDomain()
        #expect(restored.staffClefOverrides == [address: "G8vb"])
    }

    @Test func v6MigrationAddsColumnWithEmptyDefault() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.upToV5.migrate(queue)
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
            try db.execute(
                sql: """
                INSERT INTO reader_preferences (
                    id, score_item_id, staff_size, hidden_staff_ids,
                    staff_program_overrides, staff_volume_overrides, honor_layout_breaks
                ) VALUES (?, ?, 14, '[]', '[]', '[]', 1)
                """,
                arguments: [UUID().uuidString, scoreID.rawValue.uuidString]
            )
        }
        try AppMigrations.all.migrate(queue)
        let value: String? = try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT staff_clef_overrides FROM reader_preferences WHERE score_item_id = ?",
                arguments: [scoreID.rawValue.uuidString]
            )
        }
        #expect(value == "[]")
    }
}
