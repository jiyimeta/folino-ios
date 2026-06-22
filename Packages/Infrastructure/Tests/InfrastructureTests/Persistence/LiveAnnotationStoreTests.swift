@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@MainActor
struct LiveAnnotationStoreTests {
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

    private func layer(for scoreID: ScoreItemID, tick: Int) -> AnnotationLayer {
        let anchor = MusicalAnchor(
            measureIndex: 1, tickInMeasure: tick, partIndex: 0,
            staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
        return AnnotationLayer(
            scoreItemID: scoreID,
            drawings: [DrawingAnchor(anchor: anchor, encodedDrawing: Data([0x01]))],
            textBoxes: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
    }

    @Test func `save then fetch round trips the layer`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let store = LiveAnnotationStore(database: db)
        let scoreID = ScoreItemID()
        try await insertScore(db, id: scoreID)

        let saved = layer(for: scoreID, tick: 100)
        try await store.saveAnnotationLayer(saved)
        let fetched = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(fetched == saved)
    }

    @Test func `fetch on a score with no layer returns nil`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let store = LiveAnnotationStore(database: db)
        let scoreID = ScoreItemID()
        try await insertScore(db, id: scoreID)
        let result = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(result == nil)
    }

    @Test func `saving twice for the same score overwrites the layer`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let store = LiveAnnotationStore(database: db)
        let scoreID = ScoreItemID()
        try await insertScore(db, id: scoreID)

        try await store.saveAnnotationLayer(layer(for: scoreID, tick: 100))
        let second = layer(for: scoreID, tick: 200)
        try await store.saveAnnotationLayer(second)

        let fetched = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(fetched == second)
    }

    @Test func `delete removes the layer`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let store = LiveAnnotationStore(database: db)
        let scoreID = ScoreItemID()
        try await insertScore(db, id: scoreID)

        try await store.saveAnnotationLayer(layer(for: scoreID, tick: 100))
        try await store.deleteAnnotationLayer(forScoreItem: scoreID)
        let result = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(result == nil)
    }

    @Test func `soft delete keeps ink, hard delete cascades it away`() async throws {
        let (db, lifetime) = try makeDatabase()
        let scoresDir = try TempDirectory()
        defer { withExtendedLifetime((lifetime, scoresDir)) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: scoresDir.url)
        let store = LiveAnnotationStore(database: db)

        let item = ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            localFileName: "x.mid", contentHash: "h", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        try await repo.saveScoreItem(item)
        try await store.saveAnnotationLayer(layer(for: item.id, tick: 100))

        // Soft delete (trash) preserves the ink so restore brings it back.
        try await repo.softDeleteScoreItem(id: item.id)
        let afterSoft = try await store.annotationLayer(forScoreItem: item.id)
        #expect(afterSoft != nil)

        // Hard delete (permanent) cascades the layer away.
        try await repo.permanentlyDeleteScoreItem(id: item.id)
        let afterHard = try await store.annotationLayer(forScoreItem: item.id)
        #expect(afterHard == nil)
    }
}
