import Foundation
import GRDB

/// Constructs a `DatabasePool` for folino's SQLite store and runs schema
/// migrations on first use. Owned by the App composition root; the pool's
/// thread safety lets background tasks read while writes happen on the
/// writer queue.
public final class AppDatabase: Sendable {
    let pool: DatabasePool

    /// Build an on-disk database at the given URL. The parent directory
    /// must already exist (the App bootstrap creates it). Foreign-key
    /// enforcement is enabled on every connection.
    public init(databaseURL: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: databaseURL.path, configuration: config)
        try AppMigrations.all.migrate(pool)
        self.pool = pool
    }
}
