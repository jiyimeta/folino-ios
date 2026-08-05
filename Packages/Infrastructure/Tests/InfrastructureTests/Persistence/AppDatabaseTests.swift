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
        // Insert a row before v3 has been registered, then run the full migrator. The `DEFAULT` on the new column
        // should backfill the pre-existing row.
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

        // Insert a parent score row, then a v3-shape reader_preferences row (no honor_layout_breaks column yet).
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

        // Run v4. Stop at v15: v16 rebuilds the table and reclassifies a stored `1` as untouched (NULL), which is a
        // separate contract covered by `MigrationV16Tests` — running it here would hide what v4's DEFAULT does.
        try AppMigrations.upToV15.migrate(queue)

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

    @Test func `v 8 adds deleted at column with null default`() throws {
        // Insert a row at the v7 schema (no deleted_at), then run v8. The new nullable column should be NULL for the
        // pre-existing row.
        let queue = try DatabaseQueue()
        try AppMigrations.upToV7.migrate(queue)
        let scoreID = "88888888-8888-8888-8888-888888888888"
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO score_items (id, title, local_file_name, content_hash,
                    size_bytes, length_beats, default_tempo_bpm, added_at)
                VALUES (?, 'T', 'f.mscx', 'h', 0, 0, 120, 0)
                """,
                arguments: [scoreID],
            )
        }

        try AppMigrations.all.migrate(queue)

        try queue.read { db in
            let cols = try db.columns(in: "score_items").map(\.name)
            #expect(cols.contains("deleted_at"))
            let value = try Row.fetchOne(
                db,
                sql: "SELECT deleted_at FROM score_items WHERE id = ?",
                arguments: [scoreID],
            )
            #expect(value?["deleted_at"] == nil as Double?)
        }
    }

    @Test func `v 8 creates deleted at index`() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.all.migrate(queue)
        try queue.read { db in
            let indexNames = try Set(db.indexes(on: "score_items").map(\.name))
            #expect(indexNames.contains("idx_score_items_deleted_at"))
        }
    }

    @Test func `v 9 adds master volume column`() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.all.migrate(queue)

        try queue.read { db in
            let cols = try db.columns(in: "reader_preferences").map(\.name)
            #expect(cols.contains("master_volume"))
        }
    }

    @Test func `v 9 defaults existing rows to unity master volume`() throws {
        // Insert a row at the v8 schema (no master_volume), then run v9. The new column's DEFAULT 1.0 should backfill
        // the pre-existing row so prior scores play unchanged. Stops at v15 for the same reason as the v4 test above:
        // v16 reclassifies that stored 1.0 as untouched (NULL).
        let queue = try DatabaseQueue()
        try AppMigrations.upToV8.migrate(queue)
        let scoreID = "00000000-0000-0000-0000-000000000009"
        let prefsID = "99999999-9999-9999-9999-999999999999"
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

        try AppMigrations.upToV15.migrate(queue)

        try queue.read { db in
            let value = try Row.fetchOne(
                db,
                sql: "SELECT master_volume FROM reader_preferences WHERE id = ?",
                arguments: [prefsID],
            )
            #expect(value?["master_volume"] == 1.0 as Double?)
        }
    }

    @Test func `v 5 defaults existing rows to empty volume overrides JSON`() throws {
        // Insert a row at the v4 schema, then run v5. The new column's DEFAULT '[]' should backfill the pre-existing
        // row.
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

    @Test func `v 12 creates annotation layers table`() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.all.migrate(queue)
        try queue.read { db in
            try #expect(db.tableExists("annotation_layers"))
            let cols = try db.columns(in: "annotation_layers").map(\.name)
            #expect(cols.contains("id"))
            #expect(cols.contains("score_item_id"))
            #expect(cols.contains("updated_at"))
            #expect(cols.contains("payload"))
        }
    }

    @Test func `v 12 cascades annotation layer on score hard delete only`() throws {
        // FK cascade requires foreign-keys ON, which AppDatabase configures; use it over a bare DatabaseQueue.
        let tmp = try TempDirectory()
        defer { withExtendedLifetime(tmp) {} }
        let db = try AppDatabase(databaseURL: tmp.url.appending(path: "f.sqlite"))
        let scoreID = "00000000-0000-0000-0000-0000000000c1"
        try db.pool.write { db in
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
                INSERT INTO annotation_layers (id, score_item_id, updated_at, payload)
                VALUES ('a', ?, 0, x'00')
                """,
                arguments: [scoreID],
            )
        }
        // Soft-delete (UPDATE deleted_at) must NOT remove the layer.
        try db.pool.write { db in
            try db.execute(sql: "UPDATE score_items SET deleted_at = 1 WHERE id = ?", arguments: [scoreID])
        }
        let afterSoft = try db.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM annotation_layers WHERE score_item_id = ?", arguments: [scoreID],
            )
        }
        #expect(afterSoft == 1)
        // Hard-delete (DELETE row) cascades the layer away.
        try db.pool.write { db in
            try db.execute(sql: "DELETE FROM score_items WHERE id = ?", arguments: [scoreID])
        }
        let afterHard = try db.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM annotation_layers WHERE score_item_id = ?", arguments: [scoreID],
            )
        }
        #expect(afterHard == 0)
    }
}
