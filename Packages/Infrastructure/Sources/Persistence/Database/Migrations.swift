import GRDB

enum AppMigrations {
    /// The v1 migrator. Idempotent — `migrate` can be called repeatedly.
    static let v1: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        return m
    }()

    // MARK: - Private helpers

    private static func migrateV1(_ db: Database) throws {
        try createScoreItemsTable(db)
        try createTagsTable(db)
        try createPlaylistsTable(db)
        try createScoreItemTagsTable(db)
        try createPlaylistItemsTable(db)
    }

    private static func createScoreItemsTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE score_items (
            id                       TEXT    PRIMARY KEY,
            title                    TEXT    NOT NULL,
            composer                 TEXT,
            instrumentation_summary  TEXT,
            local_file_name          TEXT    NOT NULL,
            content_hash             TEXT    NOT NULL,
            size_bytes               INTEGER NOT NULL,
            length_beats             INTEGER NOT NULL,
            default_tempo_bpm        INTEGER NOT NULL,
            primary_key              TEXT,
            added_at                 REAL    NOT NULL,
            last_opened_at           REAL,
            is_favorite              INTEGER NOT NULL DEFAULT 0
        )
        """)
        try db.execute(sql: "CREATE INDEX idx_score_items_content_hash ON score_items(content_hash)")
        let lastOpenedIdx = "CREATE INDEX idx_score_items_last_opened_at ON score_items(last_opened_at DESC)"
        try db.execute(sql: lastOpenedIdx)
    }

    private static func createTagsTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE tags (
            id        TEXT PRIMARY KEY,
            name      TEXT NOT NULL,
            color_hex TEXT
        )
        """)
    }

    private static func createPlaylistsTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE playlists (
            id         TEXT PRIMARY KEY,
            name       TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """)
    }

    private static func createScoreItemTagsTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE score_item_tags (
            score_item_id  TEXT NOT NULL REFERENCES score_items(id) ON DELETE CASCADE,
            tag_id         TEXT NOT NULL REFERENCES tags(id)        ON DELETE CASCADE,
            PRIMARY KEY (score_item_id, tag_id)
        )
        """)
        try db.execute(sql: "CREATE INDEX idx_score_item_tags_tag_id ON score_item_tags(tag_id)")
    }

    private static func createPlaylistItemsTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE playlist_items (
            playlist_id    TEXT    NOT NULL REFERENCES playlists(id)   ON DELETE CASCADE,
            score_item_id  TEXT    NOT NULL REFERENCES score_items(id) ON DELETE CASCADE,
            position       INTEGER NOT NULL,
            PRIMARY KEY (playlist_id, score_item_id)
        )
        """)
        let posIdx = "CREATE INDEX idx_playlist_items_playlist_id_position ON playlist_items(playlist_id, position)"
        try db.execute(sql: posIdx)
    }
}
