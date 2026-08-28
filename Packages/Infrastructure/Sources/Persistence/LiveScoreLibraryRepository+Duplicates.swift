import Domain
import Foundation
import GRDB

/// Duplicate-detection queries, split out of `LiveScoreLibraryRepository.swift` when that file reached SwiftLint's
/// 400-line budget — the main file already does several unrelated jobs.
extension LiveScoreLibraryRepository {
    public func scoreItems(matchingContentHash contentHash: String) async throws -> [ScoreItem] {
        do {
            return try await database.pool.read { db in
                // Trashed rows are excluded so duplicate detection treats them as gone. The original PDF's hash counts
                // too: once a PDF has been read into notation the row's own `content_hash` is the `.mscz`'s, so
                // matching only that would let the same PDF be imported a second time. The captured original's hash
                // counts for the same reason once a score has been edited.
                let records = try ScoreItemRecord
                    .filter(
                        (
                            Column("content_hash") == contentHash
                                || Column("source_pdf_content_hash") == contentHash
                                || Column("original_content_hash") == contentHash
                        )
                            && Column("deleted_at") == nil,
                    )
                    .fetchAll(db)
                return try records.map { rec -> ScoreItem in
                    let tagRows = try ScoreItemTagRecord
                        .filter(Column("score_item_id") == rec.id)
                        .fetchAll(db)
                    let tagIDs = Set(tagRows.compactMap {
                        UUID(uuidString: $0.tagID).map(TagID.init(rawValue:))
                    })
                    return try rec.toDomain(tagIDs: tagIDs)
                }
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }
}
