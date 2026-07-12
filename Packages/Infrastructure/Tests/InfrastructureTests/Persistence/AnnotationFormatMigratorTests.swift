@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@MainActor
struct AnnotationFormatMigratorTests {
    private func makeDatabase() throws -> (AppDatabase, TempDirectory) {
        let tmp = try TempDirectory()
        let db = try AppDatabase(databaseURL: tmp.url.appending(path: "f.sqlite"))
        return (db, tmp)
    }

    private func insertScore(_ db: AppDatabase, id: ScoreItemID) async throws {
        try await db.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO score_items (id, title, local_file_name, content_hash,
                    size_bytes, length_beats, default_tempo_bpm, added_at)
                VALUES (?, 'T', 'f.mscx', 'h', 0, 0, 120, 0)
                """,
                arguments: [id.rawValue.uuidString],
            )
        }
    }

    @Test func `rewrites legacy drawings and is idempotent`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let store = LiveAnnotationStore(database: db)
        let scoreID = ScoreItemID()
        try await insertScore(db, id: scoreID)

        let neutralBytes = Data([0x46, 0x49, 0x4E, 0x4B, 0x01]) // "FINK" + version
        let legacyBytes = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]) // "bplist"
        // Fake transcode: any non-neutral input becomes neutral; already-neutral -> nil (unchanged).
        let transcode: @Sendable (Data) -> Data? = { d in
            d.starts(with: Data([0x46, 0x49, 0x4E, 0x4B])) ? nil : Data([0x46, 0x49, 0x4E, 0x4B, 0x01])
        }

        let anchor = MusicalAnchor(
            measureIndex: 0,
            tickInMeasure: 0,
            partIndex: 0,
            staffIndexInPart: 0,
            dxSp: 0,
            verticalOffsetSp: 0,
        )
        let layer = AnnotationLayer(
            scoreItemID: scoreID,
            drawings: [DrawingAnchor(kind: .musical(anchor), encodedDrawing: legacyBytes)],
            textBoxes: [], updatedAt: Date(timeIntervalSince1970: 0),
        )
        try await store.saveAnnotationLayer(layer)

        let migrator = AnnotationFormatMigrator(database: db)
        let firstPass = try await migrator.migrate(transcode: transcode)
        #expect(firstPass == 1)

        let migrated = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(migrated?.drawings.first?.encodedDrawing == neutralBytes)
        // Format-only rewrite must not bump the layer's mtime.
        #expect(migrated?.updatedAt == Date(timeIntervalSince1970: 0))

        // Second pass rewrites nothing (idempotent).
        let secondPass = try await migrator.migrate(transcode: transcode)
        #expect(secondPass == 0)
    }

    @Test func `rewrites only legacy drawings and leaves already-neutral drawings byte-identical`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let store = LiveAnnotationStore(database: db)
        let scoreID = ScoreItemID()
        try await insertScore(db, id: scoreID)

        let neutralBytes = Data([0x46, 0x49, 0x4E, 0x4B, 0x01]) // "FINK" + version
        let legacyBytes = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]) // "bplist"
        let alreadyNeutralBytes = Data([0x46, 0x49, 0x4E, 0x4B, 0x02]) // "FINK" + different version
        // Fake transcode: any non-neutral input becomes neutral; already-neutral -> nil (unchanged).
        let transcode: @Sendable (Data) -> Data? = { d in
            d.starts(with: Data([0x46, 0x49, 0x4E, 0x4B])) ? nil : Data([0x46, 0x49, 0x4E, 0x4B, 0x01])
        }

        let anchor = MusicalAnchor(
            measureIndex: 0,
            tickInMeasure: 0,
            partIndex: 0,
            staffIndexInPart: 0,
            dxSp: 0,
            verticalOffsetSp: 0,
        )
        let layer = AnnotationLayer(
            scoreItemID: scoreID,
            drawings: [
                DrawingAnchor(kind: .musical(anchor), encodedDrawing: legacyBytes),
                DrawingAnchor(kind: .musical(anchor), encodedDrawing: alreadyNeutralBytes),
            ],
            textBoxes: [], updatedAt: Date(timeIntervalSince1970: 0),
        )
        try await store.saveAnnotationLayer(layer)

        let migrator = AnnotationFormatMigrator(database: db)
        let rewritten = try await migrator.migrate(transcode: transcode)
        #expect(rewritten == 1)

        let migrated = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(migrated?.drawings.count == 2)
        #expect(migrated?.drawings[0].encodedDrawing == neutralBytes)
        #expect(migrated?.drawings[1].encodedDrawing == alreadyNeutralBytes)
    }
}
