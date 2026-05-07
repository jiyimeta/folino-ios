import Domain
import Foundation
import GRDB

/// Row mirror for the `reader_preferences` table. `hidden_staff_ids` is
/// stored as a JSON-encoded `[StaffAddress]` (each address serialized as
/// the two-element array `[partIndex, staffIndexInPart]`) so GRDB doesn't
/// need a custom column type for the set.
struct ReaderPreferencesRecord: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "reader_preferences"

    var id: String
    var scoreItemId: String
    var staffSize: Double
    var hiddenStaffIds: String
    var staffProgramOverrides: String
    var staffVolumeOverrides: String
    var honorLayoutBreaks: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case scoreItemId = "score_item_id"
        case staffSize = "staff_size"
        case hiddenStaffIds = "hidden_staff_ids"
        case staffProgramOverrides = "staff_program_overrides"
        case staffVolumeOverrides = "staff_volume_overrides"
        case honorLayoutBreaks = "honor_layout_breaks"
    }

    init(domain prefs: ReaderPreferences) {
        id = prefs.id.rawValue.uuidString
        scoreItemId = prefs.scoreItemID.rawValue.uuidString
        staffSize = Double(prefs.staffSize)
        let sortedAddresses = prefs.hiddenStaves.sorted()
        let hiddenData = try? JSONEncoder().encode(sortedAddresses)
        hiddenStaffIds = hiddenData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let sortedOverrides = prefs.staffProgramOverrides
            .sorted { $0.key < $1.key }
            .map { Self.encodeTriple(address: $0.key, program: $0.value) }
        let overridesData = try? JSONEncoder().encode(sortedOverrides)
        staffProgramOverrides = overridesData.flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "[]"
        let sortedVolumeOverrides = prefs.staffVolumeOverrides
            .sorted { $0.key < $1.key }
            .map { Self.encodeVolumeTriple(address: $0.key, volume: $0.value) }
        let volumeOverridesData = try? JSONEncoder().encode(sortedVolumeOverrides)
        staffVolumeOverrides = volumeOverridesData.flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "[]"
        honorLayoutBreaks = prefs.honorLayoutBreaks
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
        let decodedHidden: [StaffAddress] = (try? JSONDecoder().decode(
            [StaffAddress].self,
            from: Data(hiddenStaffIds.utf8)
        )) ?? []
        let decodedOverrides: [[Int]] = (try? JSONDecoder().decode(
            [[Int]].self,
            from: Data(staffProgramOverrides.utf8)
        )) ?? []
        var overrides: [StaffAddress: Int] = [:]
        for triple in decodedOverrides where triple.count == 3 {
            let address = StaffAddress(partIndex: triple[0], staffIndexInPart: triple[1])
            overrides[address] = triple[2]
        }
        let decodedVolumeOverrides: [[Double]] = (try? JSONDecoder().decode(
            [[Double]].self,
            from: Data(staffVolumeOverrides.utf8)
        )) ?? []
        var volumeOverrides: [StaffAddress: Double] = [:]
        for triple in decodedVolumeOverrides where triple.count == 3 {
            let address = StaffAddress(
                partIndex: Int(triple[0]),
                staffIndexInPart: Int(triple[1])
            )
            volumeOverrides[address] = triple[2]
        }
        return ReaderPreferences(
            id: ReaderPreferencesID(rawValue: idUUID),
            scoreItemID: ScoreItemID(rawValue: scoreUUID),
            staffSize: CGFloat(staffSize),
            hiddenStaves: Set(decodedHidden),
            staffProgramOverrides: overrides,
            staffVolumeOverrides: volumeOverrides,
            honorLayoutBreaks: honorLayoutBreaks
        )
    }

    private static func encodeTriple(address: StaffAddress, program: Int) -> [Int] {
        [address.partIndex, address.staffIndexInPart, program]
    }

    private static func encodeVolumeTriple(address: StaffAddress, volume: Double) -> [Double] {
        [Double(address.partIndex), Double(address.staffIndexInPart), volume]
    }
}
