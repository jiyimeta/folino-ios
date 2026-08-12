import GRDB

/// The partial migrators tests use to build a database at a given schema version, moved out of `Migrations.swift`
/// when v17 was added — that file's own header asked for this rather than growing past SwiftLint's 400-line
/// budget. Behaviour is unchanged; these are the same registrations in a different file.
extension AppMigrations {
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

    /// Migrator that registers v1 … v16 only — useful for tests that want to exercise the v17 upgrade against rows
    /// already inserted at the previous schema.
    static let upToV16: DatabaseMigrator = {
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
}
