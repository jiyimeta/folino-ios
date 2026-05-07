import Domain
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

    @Test func migrationV5BackfillsEmptyVolumeOverridesOnExistingRows() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.upToV4.migrate(queue)

        let scoreID = ScoreItemID()
        let prefsID = ReaderPreferencesID()
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
                    staff_program_overrides, honor_layout_breaks
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    prefsID.rawValue.uuidString,
                    scoreID.rawValue.uuidString,
                    14.0,
                    "[]",
                    "[]",
                    1,
                ]
            )
        }

        try AppMigrations.all.migrate(queue)

        let fetched = try queue.read {
            try ReaderPreferencesRecord
                .filter(Column("score_item_id") == scoreID.rawValue.uuidString)
                .fetchOne($0)
        }
        let unwrapped = try #require(fetched)
        #expect(unwrapped.staffVolumeOverrides == "[]")
        let restored = try unwrapped.toDomain()
        #expect(restored.staffVolumeOverrides.isEmpty)
    }
}
