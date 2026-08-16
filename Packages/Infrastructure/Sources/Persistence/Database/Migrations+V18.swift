import GRDB

extension AppMigrations {
    // MARK: - v18

    /// Adds the three columns that name, hash, and classify a score's original bytes.
    ///
    /// The interesting half is the pre-stamp. Capture is lazy — it takes the file immediately before the first edit
    /// overwrites it — which is exactly right for a row imported after this shipped, and wrong for one imported
    /// before it: the editor may already have overwritten the import bytes, and nothing in the schema records
    /// whether it did. So a `.mscx`/`.mscz` row is stamped `legacyUnknown` here, and capture keeps that value,
    /// which is what puts a caveat on that item's confirmation dialog.
    ///
    /// Every other shape is deliberately left `NULL`, because better evidence exists later:
    ///   * a row whose file is still MusicXML / MXL / MIDI has never been saved by the editor — a save would have
    ///     switched `local_file_name` to `.mscz` — so its file IS the import;
    ///   * a converted PDF whose `content_hash` still equals `pdf_derived_content_hash` is unedited, and capture
    ///     will class it `conversionOutput`;
    ///   * a `.mscz` row with an orphaned MusicXML sibling on disk is recovered at capture time, which is where the
    ///     scores directory is reachable — a migration only gets a `Database`.
    static func migrateV18(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE score_items ADD COLUMN original_file_name TEXT")
        try db.execute(sql: "ALTER TABLE score_items ADD COLUMN original_content_hash TEXT")
        try db.execute(sql: "ALTER TABLE score_items ADD COLUMN original_provenance TEXT")
        try db.execute(sql: """
        UPDATE score_items
        SET original_provenance = 'legacyUnknown'
        WHERE (LOWER(local_file_name) LIKE '%.mscz' OR LOWER(local_file_name) LIKE '%.mscx')
          AND (pdf_derived_content_hash IS NULL OR pdf_derived_content_hash <> content_hash)
        """)
    }
}
