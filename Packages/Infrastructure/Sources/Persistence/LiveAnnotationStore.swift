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
