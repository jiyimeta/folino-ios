import GRDB

/// Migration bodies live here, one `migrateVn` per version, except where a version is large enough to warrant its own
/// file — v16 (the first table rebuild) is in `Migrations+V16.swift`. This file is close to SwiftLint's 400-line
/// budget: the next migration should move the `upToVn` test-support migrators out rather than grow it further.
enum AppMigrations {
    /// Aggregate migrator that runs every registered version in order. Use this from production code (`AppDatabase`)
    /// and from tests that want a fully-migrated DB. The per-version migrators (`v1`, `v2`) remain available for
    /// migration-step-specific tests.
    static let all: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        m.registerMigration("v3", migrate: migrateV3)
        m.registerMigration("v4", migrate: migrateV4)
        m.registerMigration("v5", migrate: migrateV5)
        m.registerMigration("v6", migrate: migrateV6)
        m.registerMigration("v7", migrate: migrateV7)
        m.registerMigration("v8", migrate: migrateV8)
        m.registerMigration("v9", migrate: migrateV9)
        m.registerMigration("v10", migrate: migrateV10)
        m.registerMigration("v11", migrate: migrateV11)
        m.registerMigration("v12", migrate: migrateV12)
        m.registerMigration("v13", migrate: migrateV13)
        m.registerMigration("v14", migrate: migrateV14)
        m.registerMigration("v15", migrate: migrateV15)
        m.registerMigration("v16", migrate: migrateV16)
        return m
    }()

    /// The v1 migrator. Idempotent — `migrate` can be called repeatedly.
    static let v1: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        return m
    }()

    /// Migrator that registers v1 + v2 only — useful for tests that want to exercise a v3 upgrade against rows already
    /// inserted at the previous schema.
    static let upToV2: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        return m
    }()

    /// Migrator that registers v1 + v2 + v3 only — useful for tests that want to exercise a v4 upgrade against rows
    /// already inserted at the previous schema.
    static let upToV3: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        m.registerMigration("v3", migrate: migrateV3)
        return m
    }()

    /// Migrator that registers v1 + v2 + v3 + v4 only — useful for tests that want to exercise a v5 upgrade against
    /// rows already inserted at the previous schema.
    static let upToV4: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        m.registerMigration("v3", migrate: migrateV3)
        m.registerMigration("v4", migrate: migrateV4)
        return m
    }()

    /// Migrator that registers v1 + v2 + v3 + v4 + v5 only — useful for tests that want to exercise a v6 upgrade
    /// against rows already inserted at the previous schema.
    static let upToV5: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        m.registerMigration("v3", migrate: migrateV3)
        m.registerMigration("v4", migrate: migrateV4)
        m.registerMigration("v5", migrate: migrateV5)
        return m
    }()

    /// Migrator that registers v1 … v6 only — useful for tests that want to exercise the v7 upgrade against rows
    /// already inserted at the previous schema.
    static let upToV6: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        m.registerMigration("v3", migrate: migrateV3)
        m.registerMigration("v4", migrate: migrateV4)
        m.registerMigration("v5", migrate: migrateV5)
        m.registerMigration("v6", migrate: migrateV6)
        return m
    }()

    /// Migrator that registers v1 … v7 only — useful for tests that want to exercise the v8 upgrade against rows
    /// already inserted at the previous schema.
    static let upToV7: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        m.registerMigration("v3", migrate: migrateV3)
        m.registerMigration("v4", migrate: migrateV4)
        m.registerMigration("v5", migrate: migrateV5)
        m.registerMigration("v6", migrate: migrateV6)
        m.registerMigration("v7", migrate: migrateV7)
        return m
    }()

    /// Migrator that registers v1 … v8 only — useful for tests that want to exercise the v9 upgrade against rows
    /// already inserted at the previous schema.
    static let upToV8: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        m.registerMigration("v3", migrate: migrateV3)
        m.registerMigration("v4", migrate: migrateV4)
        m.registerMigration("v5", migrate: migrateV5)
        m.registerMigration("v6", migrate: migrateV6)
        m.registerMigration("v7", migrate: migrateV7)
        m.registerMigration("v8", migrate: migrateV8)
        return m
    }()

    /// Migrator that registers v1 … v15 only — the pre-rebuild schema, so tests can seed `reader_preferences` rows in
    /// their v15 shape (four NOT NULL scalars, no `authored_hidden_staves`) and then exercise the v16 upgrade.
    static let upToV15: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        m.registerMigration("v3", migrate: migrateV3)
        m.registerMigration("v4", migrate: migrateV4)
        m.registerMigration("v5", migrate: migrateV5)
        m.registerMigration("v6", migrate: migrateV6)
        m.registerMigration("v7", migrate: migrateV7)
        m.registerMigration("v8", migrate: migrateV8)
        m.registerMigration("v9", migrate: migrateV9)
        m.registerMigration("v10", migrate: migrateV10)
        m.registerMigration("v11", migrate: migrateV11)
        m.registerMigration("v12", migrate: migrateV12)
        m.registerMigration("v13", migrate: migrateV13)
        m.registerMigration("v14", migrate: migrateV14)
        m.registerMigration("v15", migrate: migrateV15)
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

    // MARK: - v7

    /// Adds the three playback-shape columns that `ReaderPreferences` has always carried in-memory but the record
    /// schema dropped: `repeat_mode` (cycle state), `tempo_multiplier` (override, null = native tempo), `ab_repeat`
    /// (JSON-encoded `ABRepeatRange?`, null = no range). Existing rows fall back to "off / no override / no range" via
    /// column defaults.
    private static func migrateV7(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE reader_preferences
        ADD COLUMN repeat_mode TEXT NOT NULL DEFAULT 'off'
        """)
        try db.execute(sql: """
        ALTER TABLE reader_preferences
        ADD COLUMN tempo_multiplier REAL
        """)
        try db.execute(sql: """
        ALTER TABLE reader_preferences
        ADD COLUMN ab_repeat TEXT
        """)
    }

    // MARK: - v8

    /// Adds the soft-delete column for the "Recently Deleted" feature. `deleted_at` is NULL for live rows; non-NULL
    /// means the row is in the trash and will be auto-purged 30 days after the stamp. Existing rows migrate as live
    /// (NULL) because that's the column default.
    private static func migrateV8(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE score_items
        ADD COLUMN deleted_at REAL
        """)
        try db.execute(sql: "CREATE INDEX idx_score_items_deleted_at ON score_items(deleted_at)")
    }

    // MARK: - v9

    /// Adds the per-score master output volume. `1.0` is unity (the score's authored mix); the Reader's slider
    /// boosts up to `3.0` (300%). Existing rows migrate to unity via the column default, so prior scores are unchanged.
    private static func migrateV9(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE reader_preferences
        ADD COLUMN master_volume REAL NOT NULL DEFAULT 1.0
        """)
    }

    // MARK: - v10

    /// Adds the human-readable credit columns surfaced by the Library edit sheet. All are NULL for existing rows
    /// (column default). NULL means "never edited" — the edit sheet pre-fills such fields from the on-disk file the
    /// first time it opens; an explicit empty string means the user cleared the field.
    private static func migrateV10(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE score_items ADD COLUMN arranger TEXT")
        try db.execute(sql: "ALTER TABLE score_items ADD COLUMN lyricist TEXT")
        try db.execute(sql: "ALTER TABLE score_items ADD COLUMN copyright TEXT")
    }

    // MARK: - v11

    /// Adds the per-score transposition offset and A4 reference override to `reader_preferences`. Existing rows default
    /// to 0 semitones (no transposition) and NULL Hz (inherit the global default), preserving prior behavior.
    private static func migrateV11(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE reader_preferences
        ADD COLUMN transpose_semitones INTEGER NOT NULL DEFAULT 0
        """)
        try db.execute(sql: """
        ALTER TABLE reader_preferences
        ADD COLUMN a4_reference_hz REAL
        """)
    }

    // MARK: - v12

    /// Adds the `annotation_layers` table — one ink layer per score. `score_item_id` is the primary key (at most one
    /// layer per score) and an `ON DELETE CASCADE` foreign key, so a layer is dropped only when the score row is
    /// HARD-deleted (permanent delete / 30-day purge), never on soft-delete — restoring a trashed score keeps its ink.
    /// `payload` is the JSON-encoded drawings + text boxes (the PKDrawing blobs ride inside it).
    private static func migrateV12(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE annotation_layers (
            id             TEXT NOT NULL,
            score_item_id  TEXT NOT NULL PRIMARY KEY REFERENCES score_items(id) ON DELETE CASCADE,
            updated_at     REAL NOT NULL,
            payload        BLOB NOT NULL
        )
        """)
    }

    // MARK: - v13

    /// Adds the MuseScore wire-format major version detected at import time. NULL for non-MuseScore formats (MusicXML,
    /// MIDI, PDF) and for rows imported before this migration. Analytics treats NULL as v4 (the current default), so no
    /// backfill is required.
    private static func migrateV13(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE score_items ADD COLUMN muse_score_major_version INTEGER")
    }

    // MARK: - v14

    /// Adds the "authored visibility seeded" marker to `reader_preferences`. `0` (false) means the Reader has not yet
    /// applied the score's authored `<Part><show>` hidden staves to this row. Existing rows default to `0` so they get
    /// the one-time back-fill on next open; rows the Reader seeds afterwards store `1`. Keeping user reveals sticky
    /// across reopens relies on this flag — see `ReaderPreferencesStore.loadOrSeed`.
    private static func migrateV14(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE reader_preferences
        ADD COLUMN has_seeded_authored_visibility INTEGER NOT NULL DEFAULT 0
        """)
    }

    // MARK: - v15

    /// Records where an item's notation came from when it was read out of a PDF: the original PDF sidecar's file name
    /// and hash, the hash of the `.mscz` the conversion produced (drift from `content_hash` means the user edited it),
    /// and a sticky "we tried and it wasn't readable" flag that keeps the Reader from re-running OMR on every open.
    /// All NULL / 0 for existing rows, which reads back as `PDFOriginState.notPDF`; rows that really are PDFs
    /// back-fill on their next open.
    private static func migrateV15(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE score_items ADD COLUMN source_pdf_file_name TEXT")
        try db.execute(sql: "ALTER TABLE score_items ADD COLUMN source_pdf_content_hash TEXT")
        try db.execute(sql: "ALTER TABLE score_items ADD COLUMN pdf_derived_content_hash TEXT")
        try db.execute(sql: """
        ALTER TABLE score_items
        ADD COLUMN pdf_conversion_failed INTEGER NOT NULL DEFAULT 0
        """)
    }
}
