import Foundation
import GRDB
@testable import Persistence
import Testing

/// v18 adds the three original-bytes columns and pre-stamps the rows whose original can never be recovered:
/// a MuseScore file the editor may already have overwritten. Every other shape is left `NULL` so capture can
/// classify it from better evidence later.
@Suite("Migration v18")
struct MigrationV18Tests {
    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppMigrations.upToV17.migrate(queue)
        return queue
    }

    private func insert(
        _ db: Database,
        id: String,
        localFileName: String,
        contentHash: String = "h",
        pdfDerivedContentHash: String? = nil,
    ) throws {
        try db.execute(sql: """
        INSERT INTO score_items (id, title, local_file_name, content_hash, size_bytes,
                                  length_beats, default_tempo_bpm, added_at, pdf_derived_content_hash)
        VALUES (?, 't', ?, ?, 0, 0, 120, 0, ?)
        """, arguments: [id, localFileName, contentHash, pdfDerivedContentHash])
    }

    private func provenance(_ queue: DatabaseQueue, id: String) throws -> String? {
        try queue.read { db in
            try String.fetchOne(db, sql: "SELECT original_provenance FROM score_items WHERE id = ?", arguments: [id])
        }
    }

    @Test func `a plain mscz import is stamped legacy unknown`() throws {
        let queue = try database()
        try queue.write { db in try insert(db, id: "a", localFileName: "a.mscz") }
        try AppMigrations.all.migrate(queue)
        #expect(try provenance(queue, id: "a") == "legacyUnknown")
    }

    @Test func `an mscx import is stamped legacy unknown`() throws {
        let queue = try database()
        try queue.write { db in try insert(db, id: "a", localFileName: "a.mscx") }
        try AppMigrations.all.migrate(queue)
        #expect(try provenance(queue, id: "a") == "legacyUnknown")
    }

    @Test func `a musicxml import is left unstamped`() throws {
        let queue = try database()
        try queue.write { db in try insert(db, id: "a", localFileName: "a.musicxml") }
        try AppMigrations.all.migrate(queue)
        #expect(try provenance(queue, id: "a") == nil)
    }

    @Test func `an unedited converted pdf is left unstamped`() throws {
        let queue = try database()
        try queue.write { db in
            try insert(db, id: "a", localFileName: "a.mscz", contentHash: "h", pdfDerivedContentHash: "h")
        }
        try AppMigrations.all.migrate(queue)
        #expect(try provenance(queue, id: "a") == nil)
    }

    @Test func `an already-edited converted pdf is stamped legacy unknown`() throws {
        let queue = try database()
        try queue.write { db in
            try insert(db, id: "a", localFileName: "a.mscz", contentHash: "edited", pdfDerivedContentHash: "fresh")
        }
        try AppMigrations.all.migrate(queue)
        #expect(try provenance(queue, id: "a") == "legacyUnknown")
    }

    @Test func `the file name and hash columns start empty`() throws {
        let queue = try database()
        try queue.write { db in try insert(db, id: "a", localFileName: "a.mscz") }
        try AppMigrations.all.migrate(queue)
        let (name, hash): (String?, String?) = try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db,
                sql: "SELECT original_file_name, original_content_hash FROM score_items WHERE id = 'a'",
            ))
            return (row[0], row[1])
        }
        #expect(name == nil)
        #expect(hash == nil)
    }
}
