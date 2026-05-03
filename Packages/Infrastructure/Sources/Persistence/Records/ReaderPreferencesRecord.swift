import Domain
import Foundation
import GRDB

/// Row mirror for the `reader_preferences` table. `hidden_staff_ids` is
/// stored as a JSON-encoded `[Int]` so that GRDB doesn't need a custom
/// column type for the set.
struct ReaderPreferencesRecord: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "reader_preferences"

    var id: String
    var scoreItemId: String
    var staffSize: Double
    var hiddenStaffIds: String

    enum CodingKeys: String, CodingKey {
        case id
        case scoreItemId = "score_item_id"
        case staffSize = "staff_size"
        case hiddenStaffIds = "hidden_staff_ids"
    }

    init(domain prefs: ReaderPreferences) {
        id = prefs.id.rawValue.uuidString
        scoreItemId = prefs.scoreItemID.rawValue.uuidString
        staffSize = Double(prefs.staffSize)
        let sortedIDs = prefs.hiddenStaffIDs.sorted()
        let data = try? JSONEncoder().encode(sortedIDs)
        hiddenStaffIds = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    func toDomain() throws -> ReaderPreferences {
        guard let idUUID = UUID(uuidString: id) else {
            throw DomainError.persistenceFailed(
                reason: "reader_preferences.id is not a valid UUID: \(id)")
        }
        guard let scoreUUID = UUID(uuidString: scoreItemId) else {
            throw DomainError.persistenceFailed(
                reason: "reader_preferences.score_item_id is not a valid UUID: \(scoreItemId)")
        }
        let decoded: [Int] = (try? JSONDecoder().decode(
            [Int].self,
            from: Data(hiddenStaffIds.utf8)
        )) ?? []
        return ReaderPreferences(
            id: ReaderPreferencesID(rawValue: idUUID),
            scoreItemID: ScoreItemID(rawValue: scoreUUID),
            staffSize: CGFloat(staffSize),
            hiddenStaffIDs: Set(decoded)
        )
    }
}
