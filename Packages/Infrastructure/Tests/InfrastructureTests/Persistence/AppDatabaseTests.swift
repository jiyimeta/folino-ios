import GRDB
@testable import Persistence
import Testing

struct AppDatabaseTests {
    @Test func `migrates empty database to V 1`() throws {
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

    @Test func `migration is idempotent`() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.v1.migrate(queue)
        try AppMigrations.v1.migrate(queue)
        try queue.read { db in
            try #expect(db.tableExists("score_items"))
        }
    }

    @Test func `app database factory returns usable connection`() throws {
        let tmp = try TempDirectory()
        let db = try AppDatabase(databaseURL: tmp.url.appending(path: "f.sqlite"))
        try db.pool.read { db in
            try #expect(db.tableExists("score_items"))
            try #expect(db.tableExists("reader_preferences"))
        }
    }

    @Test func `migrates empty database through V 2`() throws {
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

    @Test func `v 2 migration is idempotent`() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.all.migrate(queue)
        try AppMigrations.all.migrate(queue)
        try queue.read { db in
            try #expect(db.tableExists("reader_preferences"))
        }
    }

    @Test func `v 3 adds staff program overrides column`() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.all.migrate(queue)

        try queue.read { db in
            let cols = try db.columns(in: "reader_preferences").map(\.name)
            #expect(cols.contains("staff_program_overrides"))
        }
    }

    @Test func `v 3 defaults existing rows to empty overrides JSON`() throws {
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

    @Test func `migrating to V 4 defaults honor layout breaks to true`() throws {
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
                arguments: [scoreID],
            )
            try db.execute(
                sql: """
                INSERT INTO reader_preferences
                    (id, score_item_id, staff_size, hidden_staff_ids, staff_program_overrides)
                VALUES (?, ?, 14, '[]', '[]')
                """,
                arguments: [prefsID, scoreID],
            )
        }

        // Run v4.
        try AppMigrations.all.migrate(queue)

        let value = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT honor_layout_breaks FROM reader_preferences WHERE id = ?",
                arguments: [prefsID],
            )
        }
        #expect(value == 1)
    }

    @Test func `v 5 adds staff volume overrides column`() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.all.migrate(queue)

        try queue.read { db in
            let cols = try db.columns(in: "reader_preferences").map(\.name)
            #expect(cols.contains("staff_volume_overrides"))
        }
    }

    @Test func `v 5 defaults existing rows to empty volume overrides JSON`() throws {
        // Insert a row at the v4 schema, then run v5. The new column's
        // DEFAULT '[]' should backfill the pre-existing row.
        let queue = try DatabaseQueue()
        try AppMigrations.upToV4.migrate(queue)
        let scoreID = "00000000-0000-0000-0000-000000000002"
        let prefsID = "22222222-2222-2222-2222-222222222222"
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO score_items (id, title, local_file_name, content_hash,
                    size_bytes, length_beats, default_tempo_bpm, added_at)
                VALUES (?, 'T', 'f.mscx', 'h', 0, 0, 120, 0)
                """,
                arguments: [scoreID],
            )
            try db.execute(
                sql: """
                INSERT INTO reader_preferences
                    (id, score_item_id, staff_size, hidden_staff_ids,
                     staff_program_overrides, honor_layout_breaks)
                VALUES (?, ?, 14, '[]', '[]', 1)
                """,
                arguments: [prefsID, scoreID],
            )
        }
        try AppMigrations.all.migrate(queue)
        try queue.read { db in
            let row = try Row.fetchOne(db, sql: """
            SELECT staff_volume_overrides FROM reader_preferences WHERE id = ?
            """, arguments: [prefsID])
            #expect(row?["staff_volume_overrides"] == "[]")
        }
    }
}
