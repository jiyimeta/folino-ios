import Domain
import Foundation
import GRDB

/// One-time pass that rewrites every `annotation_layers` row's per-drawing `encodedDrawing` through an injected
/// `transcode` closure (legacy PKDrawing bytes -> neutral InkStroke bytes; `nil` = leave unchanged). Persistence must
/// not import PencilKit, so the transcode is supplied by the composition root using the Reader bridge. Idempotent:
/// a drawing already in the neutral format transcodes to `nil` and is skipped, so re-running rewrites nothing.
public struct AnnotationFormatMigrator: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Returns the number of layers actually rewritten.
    public func migrate(transcode: @Sendable (Data) -> Data?) async throws -> Int {
        do {
            let records: [AnnotationLayerRecord] = try await database.pool.read { db in
                try AnnotationLayerRecord.fetchAll(db)
            }
            var rewritten = 0
            for record in records {
                let layer = try record.toDomain()
                var changed = false
                var newDrawings = layer.drawings
                for i in newDrawings.indices {
                    if let neutral = transcode(newDrawings[i].encodedDrawing) {
                        newDrawings[i].encodedDrawing = neutral
                        changed = true
                    }
                }
                guard changed else { continue }
                let updated = AnnotationLayer(
                    id: layer.id, scoreItemID: layer.scoreItemID,
                    drawings: newDrawings, textBoxes: layer.textBoxes, updatedAt: layer.updatedAt,
                )
                let newRecord = try AnnotationLayerRecord(domain: updated)
                try await database.pool.write { db in try newRecord.save(db) }
                rewritten += 1
            }
            return rewritten
        } catch {
            throw DomainError.persistenceFailed(reason: "annotation format migration failed: \(error)")
        }
    }
}
