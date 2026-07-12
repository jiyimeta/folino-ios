@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@MainActor
struct AnnotationOpaquePreservationTests {
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

    @Test func `unknown format drawing survives round trip`() async throws {
        let (db, tmp) = try makeDatabase()
        _ = tmp
        let store = LiveAnnotationStore(database: db)
        let scoreID = ScoreItemID()
        try await insertScore(db, id: scoreID)

        let futureBytes = Data([0x00, 0x99, 0x99, 0x99, 0x42, 0x43]) // neither PKDrawing nor InkStroke
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
            drawings: [DrawingAnchor(kind: .musical(anchor), encodedDrawing: futureBytes)],
            textBoxes: [], updatedAt: Date(timeIntervalSince1970: 0),
        )
        try await store.saveAnnotationLayer(layer)
        let loaded = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(loaded?.drawings.first?.encodedDrawing == futureBytes)
    }
}
