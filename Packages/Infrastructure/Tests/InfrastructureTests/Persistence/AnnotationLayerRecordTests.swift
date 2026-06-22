@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

struct AnnotationLayerRecordTests {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppMigrations.all.migrate(q)
        return q
    }

    private func sampleLayer() -> AnnotationLayer {
        let anchor = MusicalAnchor(
            measureIndex: 4, tickInMeasure: 240, partIndex: 0,
            staffIndexInPart: 1, dxSp: 0.75, verticalOffsetSp: -3.5,
        )
        return AnnotationLayer(
            scoreItemID: ScoreItemID(),
            drawings: [
                DrawingAnchor(anchor: anchor, encodedDrawing: Data([0xDE, 0xAD, 0xBE, 0xEF])),
            ],
            textBoxes: [
                TextBoxAnchor(anchor: anchor, text: "fingering"),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
    }

    @Test func `round trips through GRDB`() throws {
        let queue = try makeQueue()
        // A parent score row is required by the FK.
        let layer = sampleLayer()
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO score_items (id, title, local_file_name, content_hash,
                    size_bytes, length_beats, default_tempo_bpm, added_at)
                VALUES (?, 'T', 'f.mscx', 'h', 0, 0, 120, 0)
                """,
                arguments: [layer.scoreItemID.rawValue.uuidString],
            )
            try AnnotationLayerRecord(domain: layer).insert(db)
        }
        let fetched = try queue.read { db -> AnnotationLayerRecord? in
            try AnnotationLayerRecord
                .filter(Column("score_item_id") == layer.scoreItemID.rawValue.uuidString)
                .fetchOne(db)
        }
        let domain = try #require(fetched).toDomain()
        #expect(domain == layer)
    }
}
