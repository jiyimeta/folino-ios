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

    /// Translate this row into a `Domain.Tag`.
    ///
    /// `colorHex` is nullable in SQLite (color is optional from the user's perspective) but `Domain.Tag.colorHex` is
    /// non-optional `String`. The codebase convention is "empty string means no color"; null DB values map to "" here
    /// so consumers don't need to special-case missing colors.
    func toDomain() throws -> Domain.Tag {
        guard let uuid = UUID(uuidString: id) else {
            throw DomainError.persistenceFailed(reason: "tags.id is not a valid UUID: \(id)")
        }
        return Domain.Tag(id: TagID(rawValue: uuid), name: name, colorHex: colorHex ?? "")
    }
}
