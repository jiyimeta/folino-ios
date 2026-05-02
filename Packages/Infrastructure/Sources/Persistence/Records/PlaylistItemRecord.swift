import GRDB

struct PlaylistItemRecord: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "playlist_items"

    var playlistID: String
    var scoreItemID: String
    var position: Int

    enum CodingKeys: String, CodingKey {
        case playlistID = "playlist_id"
        case scoreItemID = "score_item_id"
        case position
    }
}
