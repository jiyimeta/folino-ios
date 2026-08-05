import GRDB
@testable import Persistence
import Testing

/// v16 is this schema's first table rebuild (SQLite cannot drop NOT NULL in place). It reclassifies stored default
/// values as untouched (NULL) and initializes `authored_hidden_staves` from `hidden_staff_ids`. The rebuild must
/// reproduce the `score_item_id` PRIMARY KEY and its ON DELETE CASCADE — losing either silently breaks score deletes.
struct MigrationV16Tests {
    private func makeV15Database() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try AppMigrations.upToV15.migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
            INSERT INTO score_items (id, title, local_file_name, content_hash, size_bytes,
                                     length_beats, default_tempo_bpm, added_at)
            VALUES ('S1', 't', 'f1', 'h1', 0, 0, 120, 0), ('S2', 't', 'f2', 'h2', 0, 0, 120, 0)
            """)
            try db.execute(sql: """
            INSERT INTO reader_preferences
                (id, score_item_id, staff_size, hidden_staff_ids, honor_layout_breaks,
                 master_volume, transpose_semitones, repeat_mode)
            VALUES
                ('P1', 'S1', 14, '[[1,0]]', 1, 1.0, 0, 'loopAll'),
                ('P2', 'S2', 15, '[]',      0, 1.5, -3, 'off')
            """)
        }
        return dbQueue
    }

    @Test func `v16 reclassifies stored defaults as NULL and keeps explicit values`() throws {
        let dbQueue = try makeV15Database()
        try AppMigrations.all.migrate(dbQueue)
        try dbQueue.read { db in
            let row1 = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM reader_preferences WHERE score_item_id = 'S1'",
            ))
            let staffSize1: Double? = row1["staff_size"]
            let honorBreaks1: Bool? = row1["honor_layout_breaks"]
            let masterVolume1: Double? = row1["master_volume"]
            let transpose1: Int? = row1["transpose_semitones"]
            let repeatMode1: String = row1["repeat_mode"]
            let authored1: String = row1["authored_hidden_staves"]
            #expect(staffSize1 == nil)
            #expect(honorBreaks1 == nil)
            #expect(masterVolume1 == nil)
            #expect(transpose1 == nil)
            #expect(repeatMode1 == "loopAll")
            #expect(authored1 == "[[1,0]]")
            let row2 = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM reader_preferences WHERE score_item_id = 'S2'",
            ))
            let staffSize2: Double? = row2["staff_size"]
            let honorBreaks2: Bool? = row2["honor_layout_breaks"]
            let masterVolume2: Double? = row2["master_volume"]
            let transpose2: Int? = row2["transpose_semitones"]
            #expect(staffSize2 == 15)
            #expect(honorBreaks2 == false)
            #expect(masterVolume2 == 1.5)
            #expect(transpose2 == -3)
        }
    }

    /// A hand-retyped `CREATE TABLE` can silently lose a type, a NOT NULL or a DEFAULT and nothing else in the suite
    /// would notice, so diff the rebuilt table against the v15 original column by column. The four now-nullable
    /// columns also drop their DEFAULT: a row inserted without them must land as untouched (NULL), not as the default.
    @Test func `the v16 rebuild changes only the four scalars and appends one column`() throws {
        let nowNullable: Set = ["staff_size", "honor_layout_breaks", "master_volume", "transpose_semitones"]
        let v15Queue = try DatabaseQueue()
        try AppMigrations.upToV15.migrate(v15Queue)
        let before = try v15Queue.read { try $0.columns(in: "reader_preferences") }
        let v16Queue = try DatabaseQueue()
        try AppMigrations.all.migrate(v16Queue)
        let after = try v16Queue.read { try $0.columns(in: "reader_preferences") }

        #expect(before.map(\.name) + ["authored_hidden_staves"] == after.map(\.name))
        let rebuiltByName = Dictionary(uniqueKeysWithValues: after.map { ($0.name, $0) })
        for column in before {
            let rebuilt = try #require(rebuiltByName[column.name])
            #expect(rebuilt.type == column.type)
            #expect(rebuilt.primaryKeyIndex == column.primaryKeyIndex)
            if nowNullable.contains(column.name) {
                #expect(!rebuilt.isNotNull)
                #expect(rebuilt.defaultValueSQL == nil)
            } else {
                #expect(rebuilt.isNotNull == column.isNotNull)
                #expect(rebuilt.defaultValueSQL == column.defaultValueSQL)
            }
        }
        let authored = try #require(rebuiltByName["authored_hidden_staves"])
        #expect(authored.type == "TEXT")
        #expect(authored.isNotNull)
        #expect(authored.defaultValueSQL == "'[]'")
    }

    @Test func `v16 preserves the primary key and the delete cascade`() throws {
        let dbQueue = try makeV15Database()
        try AppMigrations.all.migrate(dbQueue)
        try dbQueue.write { db in
            // PK: a second row for S1 must replace/conflict, not duplicate.
            let duplicate = try? db.execute(sql: """
            INSERT INTO reader_preferences (id, score_item_id, hidden_staff_ids, authored_hidden_staves)
            VALUES ('P3', 'S1', '[]', '[]')
            """)
            #expect(duplicate == nil)
            // Cascade: deleting the score row deletes its preferences row.
            try db.execute(sql: "DELETE FROM score_items WHERE id = 'S1'")
            let remaining = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM reader_preferences WHERE score_item_id = 'S1'",
            )
            #expect(remaining == 0)
        }
    }
}
