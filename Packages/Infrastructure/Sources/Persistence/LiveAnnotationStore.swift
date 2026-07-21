import Domain
import Foundation
import GRDB

/// Live, GRDB-backed implementation of `AnnotationStore`. At most one `AnnotationLayer` per score;
/// `saveAnnotationLayer` upserts on the `score_item_id` primary key. Stateless apart from the `AppDatabase`, so it is
/// `Sendable` and needs no actor isolation — reads and writes hop onto the GRDB pool's own queues.
public final class LiveAnnotationStore: AnnotationStore {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func annotationLayer(forScoreItem id: ScoreItemID) async throws -> AnnotationLayer? {
        do {
            let key = id.rawValue.uuidString
            let record: AnnotationLayerRecord? = try await database.pool.read { db in
                try AnnotationLayerRecord
                    .filter(Column("score_item_id") == key)
                    .fetchOne(db)
            }
            return try record?.toDomain()
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func saveAnnotationLayer(_ layer: AnnotationLayer) async throws {
        do {
            let record = try AnnotationLayerRecord(domain: layer)
            try await database.pool.write { db in
                try record.save(db)
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func deleteAnnotationLayer(forScoreItem id: ScoreItemID) async throws {
        do {
            let key = id.rawValue.uuidString
            try await database.pool.write { db in
                _ = try AnnotationLayerRecord
                    .filter(Column("score_item_id") == key)
                    .deleteAll(db)
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }
}

// MARK: - AnnotationBlobStore (shared coordinator write path)

/// Raw-bytes face of the SAME `annotation_layers` table, driven by the shared `AnnotationSaveCoordinator`. The payload
/// is stored verbatim — the coordinator already encoded it with `AnnotationLayerCodec` (byte-identical to
/// `AnnotationLayerRecord.Body`), so there is no domain round-trip and existing blobs interoperate with the
/// `AnnotationStore` face above. Both faces key on `score_item_id` (at most one layer per score), so they stay
/// consistent regardless of which one wrote last.
extension LiveAnnotationStore: AnnotationBlobStore {
    public func load(scoreID: ScoreItemID) async throws -> Data? {
        do {
            let key = scoreID.rawValue.uuidString
            return try await database.pool.read { db in
                try AnnotationLayerRecord
                    .filter(Column("score_item_id") == key)
                    .fetchOne(db)?
                    .payload
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func save(scoreID: ScoreItemID, updatedAt: Date, payload: Data) async throws {
        do {
            let record = AnnotationLayerRecord(
                id: UUID().uuidString,
                scoreItemId: scoreID.rawValue.uuidString,
                updatedAt: updatedAt.timeIntervalSince1970,
                payload: payload,
            )
            try await database.pool.write { db in
                try record.save(db)
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func delete(scoreID: ScoreItemID) async throws {
        do {
            let key = scoreID.rawValue.uuidString
            try await database.pool.write { db in
                _ = try AnnotationLayerRecord
                    .filter(Column("score_item_id") == key)
                    .deleteAll(db)
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }
}
