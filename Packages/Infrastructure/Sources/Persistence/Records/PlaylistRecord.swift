import Domain
import Foundation
import GRDB

struct PlaylistRecord: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "playlists"

    var id: String
    var name: String
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "created_at"
    }

    init(domain playlist: Playlist) {
        id = playlist.id.rawValue.uuidString
        name = playlist.name
        createdAt = playlist.createdAt.timeIntervalSince1970
    }

    func toDomain(orderedScoreItemIDs: [ScoreItemID]) throws -> Playlist {
        guard let uuid = UUID(uuidString: id) else {
            throw DomainError.persistenceFailed(reason: "playlists.id is not a valid UUID: \(id)")
        }
        return Playlist(
            id: PlaylistID(rawValue: uuid),
            name: name,
            orderedScoreItemIDs: orderedScoreItemIDs,
            createdAt: Date(timeIntervalSince1970: createdAt),
        )
    }
}
