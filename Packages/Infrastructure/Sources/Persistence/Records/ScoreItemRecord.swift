import Domain
import Foundation
import GRDB

/// Row mirror for the `score_items` table. Tag IDs are NOT stored on this
/// record — they live in `score_item_tags` and are joined in by the
/// repository before building a `ScoreItem`.
struct ScoreItemRecord: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "score_items"

    var id: String
    var title: String
    var subtitle: String?
    var composer: String?
    var instrumentationSummary: String?
    var localFileName: String
    var contentHash: String
    var sizeBytes: Int64
    var lengthBeats: Int
    var defaultTempoBpm: Int
    var primaryKey: String?
    var addedAt: Double
    var lastOpenedAt: Double?
    var isFavorite: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case composer
        case instrumentationSummary = "instrumentation_summary"
        case localFileName = "local_file_name"
        case contentHash = "content_hash"
        case sizeBytes = "size_bytes"
        case lengthBeats = "length_beats"
        case defaultTempoBpm = "default_tempo_bpm"
        case primaryKey = "primary_key"
        case addedAt = "added_at"
        case lastOpenedAt = "last_opened_at"
        case isFavorite = "is_favorite"
    }

    init(domain item: ScoreItem) {
        id = item.id.rawValue.uuidString
        title = item.title
        subtitle = item.subtitle
        composer = item.composer
        instrumentationSummary = item.instrumentationSummary
        localFileName = item.localFileName
        contentHash = item.contentHash
        sizeBytes = item.sizeBytes
        lengthBeats = item.lengthBeats
        defaultTempoBpm = item.defaultTempoBpm
        primaryKey = item.primaryKey
        addedAt = item.addedAt.timeIntervalSince1970
        lastOpenedAt = item.lastOpenedAt?.timeIntervalSince1970
        isFavorite = item.isFavorite
    }

    func toDomain(tagIDs: Set<TagID>) throws -> ScoreItem {
        guard let uuid = UUID(uuidString: id) else {
            throw DomainError.persistenceFailed(reason: "score_items.id is not a valid UUID: \(id)")
        }
        return ScoreItem(
            id: ScoreItemID(rawValue: uuid),
            title: title,
            subtitle: subtitle,
            composer: composer,
            instrumentationSummary: instrumentationSummary,
            localFileName: localFileName,
            contentHash: contentHash,
            sizeBytes: sizeBytes,
            lengthBeats: lengthBeats,
            defaultTempoBpm: defaultTempoBpm,
            primaryKey: primaryKey,
            addedAt: Date(timeIntervalSince1970: addedAt),
            lastOpenedAt: lastOpenedAt.map(Date.init(timeIntervalSince1970:)),
            tagIDs: tagIDs,
            isFavorite: isFavorite,
        )
    }
}
