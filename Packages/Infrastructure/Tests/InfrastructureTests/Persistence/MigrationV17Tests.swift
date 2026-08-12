import Foundation
import GRDB
@testable import Persistence
import Testing

/// v17 re-reads the two override columns as strip-keyed. A staff key and a strip key are both two integers, so
/// the rows survive decoding either way and would silently mean a different sound; the migration drops every row
/// whose second integer is not 0, which is the part's first entry and the only one a strip can inherit.
@Suite("Migration v17")
struct MigrationV17Tests {
    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppMigrations.upToV16.migrate(queue)
        return queue
    }

    private func insertScoreItem(_ db: Database) throws {
        try db.execute(sql: """
        INSERT INTO score_items (id, title, local_file_name, content_hash, size_bytes,
                                  length_beats, default_tempo_bpm, added_at)
        VALUES ('score-1', 't', 'f1', 'h1', 0, 0, 120, 0)
        """)
    }

    private func insertRow(_ db: Database, volumes: String, programs: String) throws {
        try db.execute(sql: """
        INSERT INTO reader_preferences (id, score_item_id, hidden_staff_ids, staff_program_overrides,
            staff_volume_overrides, staff_clef_overrides, repeat_mode, has_seeded_authored_visibility,
            authored_hidden_staves)
        VALUES ('id-1', 'score-1', '[]', ?, ?, '[]', 'off', 1, '[]')
        """, arguments: [programs, volumes])
    }

    @Test func `drops every override past a part's first staff`() throws {
        let queue = try database()
        try queue.write { db in
            try insertScoreItem(db)
            try insertRow(db, volumes: "[[0,0,0.25],[0,1,0.75],[1,0,0.5]]", programs: "[[0,0,40],[0,1,40]]")
        }

        try AppMigrations.all.migrate(queue)

        let (volumes, programs): (String, String) = try queue.read { db in
            let row = try #require(try Row.fetchOne(db, sql: """
            SELECT staff_volume_overrides, staff_program_overrides FROM reader_preferences
            """))
            return (row[0], row[1])
        }
        #expect(volumes == "[[0,0,0.25],[1,0,0.5]]")
        #expect(programs == "[[0,0,40]]")
    }

    @Test func `leaves a row with no multi-staff entries byte-identical`() throws {
        let queue = try database()
        try queue.write { db in
            try insertScoreItem(db)
            try insertRow(db, volumes: "[[0,0,0.25],[1,0,0.5]]", programs: "[]")
        }

        try AppMigrations.all.migrate(queue)

        let volumes: String = try queue.read { db in
            try #require(try String.fetchOne(db, sql: "SELECT staff_volume_overrides FROM reader_preferences"))
        }
        #expect(volumes == "[[0,0,0.25],[1,0,0.5]]")
    }

    /// The record decoders swallow malformed JSON rather than failing a read, so the migration must not be the
    /// one thing that throws on a row the app would otherwise open.
    @Test func `survives malformed column JSON`() throws {
        let queue = try database()
        try queue.write { db in
            try insertScoreItem(db)
            try insertRow(db, volumes: "not json", programs: "[]")
        }

        try AppMigrations.all.migrate(queue)

        let volumes: String = try queue.read { db in
            try #require(try String.fetchOne(db, sql: "SELECT staff_volume_overrides FROM reader_preferences"))
        }
        #expect(volumes == "[]")
    }
}
