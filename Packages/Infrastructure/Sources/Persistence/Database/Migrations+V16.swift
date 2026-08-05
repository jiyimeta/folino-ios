import GRDB

/// v16 lives in its own file because it is the first migration that rebuilds a table rather than adding a column, so
/// it carries a full `CREATE TABLE` — inlining it pushed `Migrations.swift` past SwiftLint's 400-line file budget.
/// Registered by `AppMigrations.all` there; `migrateV16` is `internal` (not `private`) only so that registration can
/// reach across the file boundary.
extension AppMigrations {
    // MARK: - v16

    /// First table rebuild in this schema: SQLite cannot drop a NOT NULL constraint in place, so `reader_preferences`
    /// is recreated with `staff_size` / `honor_layout_breaks` / `master_volume` / `transpose_semitones` nullable
    /// (NULL == the user never touched the setting) plus the new `authored_hidden_staves` provenance column. Stored
    /// default values (14 / 1 / 1.0 / 0) are reclassified as untouched — the accepted tradeoff of the 2026-08-05
    /// per-score-prefs spec. `authored_hidden_staves` starts as a copy of `hidden_staff_ids` (conservative: all
    /// pre-v16 hides read as authored) and self-heals on each score's next open. The rebuild reproduces the
    /// `score_item_id` PRIMARY KEY and its `ON DELETE CASCADE` from v2 — GRDB defers foreign keys during migration and
    /// re-checks after, so the standard create-copy-drop-rename recipe is safe.
    ///
    /// The four now-nullable columns also lose their `DEFAULT` clauses: a row inserted without them must land as
    /// untouched (NULL), not as an explicit default. Every other column keeps its v2…v14 type, NOT NULL-ness and
    /// default verbatim — `MigrationV16Tests` diffs the rebuilt table against v15 to hold that.
    static func migrateV16(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE reader_preferences_new (
            id                             TEXT    NOT NULL,
            score_item_id                  TEXT    NOT NULL PRIMARY KEY REFERENCES score_items(id) ON DELETE CASCADE,
            staff_size                     REAL,
            hidden_staff_ids               TEXT    NOT NULL,
            staff_program_overrides        TEXT    NOT NULL DEFAULT '[]',
            honor_layout_breaks            INTEGER,
            staff_volume_overrides         TEXT    NOT NULL DEFAULT '[]',
            staff_clef_overrides           TEXT    NOT NULL DEFAULT '[]',
            repeat_mode                    TEXT    NOT NULL DEFAULT 'off',
            tempo_multiplier               REAL,
            ab_repeat                      TEXT,
            master_volume                  REAL,
            transpose_semitones            INTEGER,
            a4_reference_hz                REAL,
            has_seeded_authored_visibility INTEGER NOT NULL DEFAULT 0,
            authored_hidden_staves         TEXT    NOT NULL DEFAULT '[]'
        )
        """)
        try db.execute(sql: """
        INSERT INTO reader_preferences_new
            (id, score_item_id, staff_size, hidden_staff_ids, staff_program_overrides, honor_layout_breaks,
             staff_volume_overrides, staff_clef_overrides, repeat_mode, tempo_multiplier, ab_repeat,
             master_volume, transpose_semitones, a4_reference_hz, has_seeded_authored_visibility,
             authored_hidden_staves)
        SELECT
            id, score_item_id,
            CASE WHEN staff_size = 14 THEN NULL ELSE staff_size END,
            hidden_staff_ids, staff_program_overrides,
            CASE WHEN honor_layout_breaks = 1 THEN NULL ELSE honor_layout_breaks END,
            staff_volume_overrides, staff_clef_overrides, repeat_mode, tempo_multiplier, ab_repeat,
            CASE WHEN master_volume = 1.0 THEN NULL ELSE master_volume END,
            CASE WHEN transpose_semitones = 0 THEN NULL ELSE transpose_semitones END,
            a4_reference_hz, has_seeded_authored_visibility,
            hidden_staff_ids
        FROM reader_preferences
        """)
        try db.execute(sql: "DROP TABLE reader_preferences")
        try db.execute(sql: "ALTER TABLE reader_preferences_new RENAME TO reader_preferences")
    }
}
