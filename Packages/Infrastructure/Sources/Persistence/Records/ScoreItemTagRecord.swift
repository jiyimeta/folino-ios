import GRDB

struct ScoreItemTagRecord: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "score_item_tags"

    var scoreItemID: String
    var tagID: String

    enum CodingKeys: String, CodingKey {
        case scoreItemID = "score_item_id"
        case tagID = "tag_id"
    }
}
