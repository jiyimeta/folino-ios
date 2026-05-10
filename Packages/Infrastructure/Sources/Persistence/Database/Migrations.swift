import GRDB

enum AppMigrations {
    /// Aggregate migrator that runs every registered version in order.
    /// Use this from production code (`AppDatabase`) and from tests that
    /// want a fully-migrated DB. The per-version migrators (`v1`, `v2`)
    /// remain available for migration-step-specific tests.
    static let all: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        m.registerMigration("v3", migrate: migrateV3)
        m.registerMigration("v4", migrate: migrateV4)
        m.registerMigration("v5", migrate: migrateV5)
        m.registerMigration("v6", migrate: migrateV6)
        return m
    }()

    /// The v1 migrator. Idempotent — `migrate` can be called repeatedly.
    static let v1: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        return m
    }()

    /// Migrator that registers v1 + v2 only — useful for tests that want to
    /// exercise a v3 upgrade against rows already inserted at the previous
    /// schema.
    static let upToV2: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        return m
    }()

    /// Migrator that registers v1 + v2 + v3 only — useful for tests that
    /// want to exercise a v4 upgrade against rows already inserted at the
    /// previous schema.
    static let upToV3: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        m.registerMigration("v3", migrate: migrateV3)
        return m
    }()

    /// Migrator that registers v1 + v2 + v3 + v4 only — useful for tests
    /// that want to exercise a v5 upgrade against rows already inserted at
    /// the previous schema.
    static let upToV4: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        m.registerMigration("v3", migrate: migrateV3)
        m.registerMigration("v4", migrate: migrateV4)
        return m
    }()

    /// Migrator that registers v1 + v2 + v3 + v4 + v5 only — useful for
    /// tests that want to exercise a v6 upgrade against rows already
    /// inserted at the previous schema.
    static let upToV5: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        m.registerMigration("v3", migrate: migrateV3)
        m.registerMigration("v4", migrate: migrateV4)
        m.registerMigration("v5", migrate: migrateV5)
        return m
    }()

    // MARK: - v1

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
            subtitle                 TEXT,
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

    // MARK: - v2

    private static func migrateV2(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE reader_preferences (
            id                TEXT NOT NULL,
            score_item_id     TEXT NOT NULL PRIMARY KEY REFERENCES score_items(id) ON DELETE CASCADE,
            staff_size        REAL NOT NULL,
            hidden_staff_ids  TEXT NOT NULL
        )
        """)
    }

    // MARK: - v3

    private static func migrateV3(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE reader_preferences
        ADD COLUMN staff_program_overrides TEXT NOT NULL DEFAULT '[]'
        """)
    }

    // MARK: - v4

    private static func migrateV4(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE reader_preferences
        ADD COLUMN honor_layout_breaks INTEGER NOT NULL DEFAULT 1
        """)
    }

    // MARK: - v5

    private static func migrateV5(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE reader_preferences
        ADD COLUMN staff_volume_overrides TEXT NOT NULL DEFAULT '[]'
        """)
    }

    // MARK: - v6

    private static func migrateV6(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE reader_preferences
        ADD COLUMN staff_clef_overrides TEXT NOT NULL DEFAULT '[]'
        """)
    }
}
