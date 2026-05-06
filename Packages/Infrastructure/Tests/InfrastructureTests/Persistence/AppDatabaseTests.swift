import GRDB
@testable import Persistence
import Testing

@Suite struct AppDatabaseTests {
    @Test func migratesEmptyDatabaseToV1() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.v1.migrate(queue)

        try queue.read { db in
            // All tables exist.
            try #expect(db.tableExists("score_items"))
            try #expect(db.tableExists("tags"))
            try #expect(db.tableExists("playlists"))
            try #expect(db.tableExists("score_item_tags"))
            try #expect(db.tableExists("playlist_items"))

            // Indexes exist.
            let indexNames = try Set(db.indexes(on: "score_items").map(\.name))
            #expect(indexNames.contains("idx_score_items_content_hash"))
            #expect(indexNames.contains("idx_score_items_last_opened_at"))
        }
    }

    @Test func migrationIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.v1.migrate(queue)
        try AppMigrations.v1.migrate(queue)
        try queue.read { db in
            try #expect(db.tableExists("score_items"))
        }
    }

    @Test func appDatabaseFactoryReturnsUsableConnection() throws {
        let tmp = try TempDirectory()
        let db = try AppDatabase(databaseURL: tmp.url.appending(path: "f.sqlite"))
        try db.pool.read { db in
            try #expect(db.tableExists("score_items"))
            try #expect(db.tableExists("reader_preferences"))
        }
    }

    @Test func migratesEmptyDatabaseThroughV2() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.all.migrate(queue)

        try queue.read { db in
            try #expect(db.tableExists("reader_preferences"))

            let cols = try db.columns(in: "reader_preferences").map(\.name)
            #expect(cols.contains("id"))
            #expect(cols.contains("score_item_id"))
            #expect(cols.contains("staff_size"))
            #expect(cols.contains("hidden_staff_ids"))
        }
    }

    @Test func v2MigrationIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.all.migrate(queue)
        try AppMigrations.all.migrate(queue)
        try queue.read { db in
            try #expect(db.tableExists("reader_preferences"))
        }
    }

    @Test func v3AddsStaffProgramOverridesColumn() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.all.migrate(queue)

        try queue.read { db in
            let cols = try db.columns(in: "reader_preferences").map(\.name)
            #expect(cols.contains("staff_program_overrides"))
        }
    }

    @Test func v3DefaultsExistingRowsToEmptyOverridesJSON() throws {
        // Insert a row before v3 has been registered, then run the full
        // migrator. The `DEFAULT` on the new column should backfill the
        // pre-existing row.
        let queue = try DatabaseQueue()
        try AppMigrations.upToV2.migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO score_items (id, title, local_file_name, content_hash,
                size_bytes, length_beats, default_tempo_bpm, added_at)
            VALUES ('s', 'T', 'f.mscx', 'h', 0, 0, 120, 0)
            """)
            try db.execute(sql: """
            INSERT INTO reader_preferences
                (id, score_item_id, staff_size, hidden_staff_ids)
            VALUES ('p', 's', 14.0, '[]')
            """)
        }
        try AppMigrations.all.migrate(queue)
        try queue.read { db in
            let row = try Row.fetchOne(db, sql: """
            SELECT staff_program_overrides FROM reader_preferences WHERE id = 'p'
            """)
            #expect(row?["staff_program_overrides"] == "[]")
        }
    }

    @Test func migratingToV4DefaultsHonorLayoutBreaksToTrue() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.upToV3.migrate(queue)

        // Insert a parent score row, then a v3-shape reader_preferences row
        // (no honor_layout_breaks column yet).
        let scoreID = "00000000-0000-0000-0000-000000000001"
        let prefsID = "11111111-1111-1111-1111-111111111111"
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO score_items (id, title, local_file_name, content_hash,
                    size_bytes, length_beats, default_tempo_bpm, added_at)
                VALUES (?, 'T', 'f.mscx', 'h', 0, 0, 120, 0)
                """,
                arguments: [scoreID]
            )
            try db.execute(
                sql: """
                INSERT INTO reader_preferences
                    (id, score_item_id, staff_size, hidden_staff_ids, staff_program_overrides)
                VALUES (?, ?, 14, '[]', '[]')
                """,
                arguments: [prefsID, scoreID]
            )
        }

        // Run v4.
        try AppMigrations.all.migrate(queue)

        let value = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT honor_layout_breaks FROM reader_preferences WHERE id = ?",
                arguments: [prefsID]
            )
        }
        #expect(value == 1)
    }
}
