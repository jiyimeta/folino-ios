import Domain
import Foundation
import GRDB

struct TagRecord: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "tags"

    var id: String
    var name: String
    var colorHex: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case colorHex = "color_hex"
    }

    init(domain tag: Domain.Tag) {
        id = tag.id.rawValue.uuidString
        name = tag.name
        colorHex = tag.colorHex
    }

    func toDomain() throws -> Domain.Tag {
        guard let uuid = UUID(uuidString: id) else {
            throw DomainError.persistenceFailed(reason: "tags.id is not a valid UUID: \(id)")
        }
        return Domain.Tag(id: TagID(rawValue: uuid), name: name, colorHex: colorHex ?? "")
    }
}
