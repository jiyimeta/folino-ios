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
}
