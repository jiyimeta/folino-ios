import Domain
import Foundation
import GRDB
@testable import Persistence
import SheetMusicCore
import Testing

struct ReaderPreferencesRecordTests {
    @Test func `round trips through domain`() throws {
        let scoreID = ScoreItemID()
        let prefs = ReaderPreferences(
            scoreItemID: scoreID,
            staffSize: 12,
            hiddenStaves: [
                StaffAddress(partIndex: 0, staffIndexInPart: 0),
                StaffAddress(partIndex: 1, staffIndexInPart: 1),
            ],
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored == prefs)
    }

    @Test func `encodes and decodes via SQ lite`() throws {
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
                arguments: [scoreID.rawValue.uuidString],
            )
        }
        let hidden: Set<StaffAddress> = [StaffAddress(partIndex: 1, staffIndexInPart: 0)]
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, staffSize: 16, hiddenStaves: hidden,
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

    @Test func `has-seeded-authored-visibility round trips through SQLite`() throws {
        // Exercises the v14 `has_seeded_authored_visibility` column added by AppMigrations.all.
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
                arguments: [scoreID.rawValue.uuidString],
            )
        }
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, staffSize: 14, hiddenStaves: [],
            hasSeededAuthoredVisibility: true,
        )
        try queue.write { try ReaderPreferencesRecord(domain: prefs).save($0) }
        let fetched = try queue.read {
            try ReaderPreferencesRecord
                .filter(Column("score_item_id") == scoreID.rawValue.uuidString)
                .fetchOne($0)
        }
        let restored = try #require(fetched).toDomain()
        #expect(restored.hasSeededAuthoredVisibility)
    }

    @Test func `empty hidden set encodes as empty JSON`() {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [],
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        #expect(record.hiddenStaffIds == "[]")
    }

    @Test func `empty program overrides encodes as empty JSON`() {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [],
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        #expect(record.staffProgramOverrides == "[]")
    }

    @Test func `program overrides round trip through domain`() throws {
        let address1 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let address2 = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffProgramOverrides: [address1: 6, address2: 40],
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.staffProgramOverrides == [address1: 6, address2: 40])
    }

    @Test func `honor layout breaks round trips through domain`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            honorLayoutBreaks: false,
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.honorLayoutBreaks == false)
    }

    @Test func `honor layout breaks defaults to true on domain construction`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
        )
        #expect(prefs.honorLayoutBreaks == true)
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.honorLayoutBreaks == true)
    }

    @Test func `empty volume overrides encodes as empty JSON`() {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [],
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        #expect(record.staffVolumeOverrides == "[]")
    }

    @Test func `volume overrides round trip through domain`() throws {
        let address1 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let address2 = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffVolumeOverrides: [address1: 0.25, address2: 0.75],
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.staffVolumeOverrides == [address1: 0.25, address2: 0.75])
    }

    @Test func `empty clef overrides encodes as empty JSON`() {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [],
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        #expect(record.staffClefOverrides == "[]")
    }

    @Test func `clef overrides round trip through domain`() throws {
        let address1 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let address2 = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffClefOverrides: [address1: "G8vb", address2: "F"],
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.staffClefOverrides == [address1: "G8vb", address2: "F"])
    }

    @Test func `clef overrides persist through SQ lite`() throws {
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
                arguments: [scoreID.rawValue.uuidString],
            )
        }
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        let prefs = ReaderPreferences(
            scoreItemID: scoreID,
            staffSize: 14,
            hiddenStaves: [],
            staffClefOverrides: [address: "G8vb"],
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

    @Test func `repeat mode round trips through domain`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            repeatMode: .loopAll,
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.repeatMode == .loopAll)
    }

    @Test func `repeat mode defaults to off when not specified`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [],
        )
        #expect(prefs.repeatMode == .off)
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.repeatMode == .off)
    }

    @Test func `tempo multiplier round trips through domain`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 0.75,
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.tempoMultiplier == 0.75)
    }

    @Test func `nil tempo multiplier round trips as nil`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: nil,
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.tempoMultiplier == nil)
    }

    @Test func `master volume round trips through domain`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            masterVolume: 2.5,
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        #expect(record.masterVolume == 2.5)
        let restored = try record.toDomain()
        #expect(restored.masterVolume == 2.5)
    }

    @Test func `ab repeat round trips through domain`() throws {
        let start = ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 0)
        let end = ChordPath(systemIndex: 0, measureIndex: 3, voiceIndex: 0, chordIndex: 2)
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            repeatMode: .abLoop,
            abRepeat: ABRepeatRange(start: start, end: end),
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.abRepeat?.start == start)
        #expect(restored.abRepeat?.end == end)
    }

    @Test func `nil ab repeat round trips as nil`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            abRepeat: nil,
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.abRepeat == nil)
    }

    @Test func `repeat mode persists through SQ lite`() throws {
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
                arguments: [scoreID.rawValue.uuidString],
            )
        }
        let start = ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 0)
        let end = ChordPath(systemIndex: 0, measureIndex: 4, voiceIndex: 0, chordIndex: 1)
        let prefs = ReaderPreferences(
            scoreItemID: scoreID,
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 0.5,
            repeatMode: .abLoop,
            abRepeat: ABRepeatRange(start: start, end: end),
        )
        try queue.write { try ReaderPreferencesRecord(domain: prefs).save($0) }
        let fetched = try queue.read {
            try ReaderPreferencesRecord
                .filter(Column("score_item_id") == scoreID.rawValue.uuidString)
                .fetchOne($0)
        }
        let restored = try #require(fetched).toDomain()
        #expect(restored.repeatMode == .abLoop)
        #expect(restored.tempoMultiplier == 0.5)
        #expect(restored.abRepeat?.start == start)
        #expect(restored.abRepeat?.end == end)
    }

    @Test func `v 7 migration adds columns with defaults`() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.upToV6.migrate(queue)
        let scoreID = ScoreItemID()
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO score_items (id, title, local_file_name, content_hash,
                    size_bytes, length_beats, default_tempo_bpm, added_at)
                VALUES (?, 'T', 'f.mscx', 'h', 0, 0, 120, 0)
                """,
                arguments: [scoreID.rawValue.uuidString],
            )
            try db.execute(
                sql: """
                INSERT INTO reader_preferences (
                    id, score_item_id, staff_size, hidden_staff_ids,
                    staff_program_overrides, staff_volume_overrides,
                    staff_clef_overrides, honor_layout_breaks
                ) VALUES (?, ?, 14, '[]', '[]', '[]', '[]', 1)
                """,
                arguments: [UUID().uuidString, scoreID.rawValue.uuidString],
            )
        }
        try AppMigrations.all.migrate(queue)

        // After the v7 upgrade the row is still loadable and the new columns surface as the documented defaults.
        let restored = try queue.read { db in
            try ReaderPreferencesRecord
                .filter(Column("score_item_id") == scoreID.rawValue.uuidString)
                .fetchOne(db)
        }
        let unwrapped = try #require(restored).toDomain()
        #expect(unwrapped.repeatMode == .off)
        #expect(unwrapped.tempoMultiplier == nil)
        #expect(unwrapped.abRepeat == nil)
    }

    @Test func `v 6 migration adds column with empty default`() throws {
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
                arguments: [scoreID.rawValue.uuidString],
            )
            try db.execute(
                sql: """
                INSERT INTO reader_preferences (
                    id, score_item_id, staff_size, hidden_staff_ids,
                    staff_program_overrides, staff_volume_overrides, honor_layout_breaks
                ) VALUES (?, ?, 14, '[]', '[]', '[]', 1)
                """,
                arguments: [UUID().uuidString, scoreID.rawValue.uuidString],
            )
        }
        try AppMigrations.all.migrate(queue)
        let value: String? = try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT staff_clef_overrides FROM reader_preferences WHERE score_item_id = ?",
                arguments: [scoreID.rawValue.uuidString],
            )
        }
        #expect(value == "[]")
    }
}
