import Domain
import Foundation
import GRDB

/// Row mirror for the `reader_preferences` table. `hidden_staff_ids` is stored as a JSON-encoded `[StaffAddress]` (each
/// address serialized as the two-element array `[partIndex, staffIndexInPart]`) so GRDB doesn't need a custom column
/// type for the set.
struct ReaderPreferencesRecord: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "reader_preferences"

    var id: String
    var scoreItemId: String
    var staffSize: Double
    var hiddenStaffIds: String
    var staffProgramOverrides: String
    var staffVolumeOverrides: String
    var staffClefOverrides: String
    var honorLayoutBreaks: Bool
    var repeatMode: String
    var tempoMultiplier: Double?
    var abRepeat: String?

    enum CodingKeys: String, CodingKey {
        case id
        case scoreItemId = "score_item_id"
        case staffSize = "staff_size"
        case hiddenStaffIds = "hidden_staff_ids"
        case staffProgramOverrides = "staff_program_overrides"
        case staffVolumeOverrides = "staff_volume_overrides"
        case staffClefOverrides = "staff_clef_overrides"
        case honorLayoutBreaks = "honor_layout_breaks"
        case repeatMode = "repeat_mode"
        case tempoMultiplier = "tempo_multiplier"
        case abRepeat = "ab_repeat"
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
        let sortedClefOverrides = prefs.staffClefOverrides
            .sorted { $0.key < $1.key }
            .map { Self.encodeClefTriple(address: $0.key, rawType: $0.value) }
        let clefOverridesData = try? JSONEncoder().encode(sortedClefOverrides)
        staffClefOverrides = clefOverridesData.flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "[]"
        honorLayoutBreaks = prefs.honorLayoutBreaks
        repeatMode = prefs.repeatMode.rawValue
        tempoMultiplier = prefs.tempoMultiplier
        if let range = prefs.abRepeat,
           let data = try? JSONEncoder().encode(range)
        {
            abRepeat = String(data: data, encoding: .utf8)
        } else {
            abRepeat = nil
        }
    }

    func toDomain() throws -> ReaderPreferences {
        guard let idUUID = UUID(uuidString: id) else {
            throw DomainError.persistenceFailed(
                reason: "reader_preferences.id is not a valid UUID: \(id)",
            )
        }
        guard let scoreUUID = UUID(uuidString: scoreItemId) else {
            throw DomainError.persistenceFailed(
                reason: "reader_preferences.score_item_id is not a valid UUID: \(scoreItemId)",
            )
        }
        // Unknown repeat mode strings (e.g. SQL column hand-edited or a future value rolled back to an older binary)
        // fall back to `.off` — preserves the row instead of failing the whole fetch.
        let decodedRepeatMode = RepeatMode(rawValue: repeatMode) ?? .off
        let decodedAbRepeat: ABRepeatRange? = abRepeat.flatMap { json in
            try? JSONDecoder().decode(ABRepeatRange.self, from: Data(json.utf8))
        }
        return ReaderPreferences(
            id: ReaderPreferencesID(rawValue: idUUID),
            scoreItemID: ScoreItemID(rawValue: scoreUUID),
            staffSize: CGFloat(staffSize),
            hiddenStaves: Self.decodeHidden(hiddenStaffIds),
            staffProgramOverrides: Self.decodeProgramOverrides(staffProgramOverrides),
            staffVolumeOverrides: Self.decodeVolumeOverrides(staffVolumeOverrides),
            staffClefOverrides: Self.decodeClefOverrides(staffClefOverrides),
            tempoMultiplier: tempoMultiplier,
            honorLayoutBreaks: honorLayoutBreaks,
            repeatMode: decodedRepeatMode,
            abRepeat: decodedAbRepeat,
        )
    }

    private static func decodeHidden(_ json: String) -> Set<StaffAddress> {
        let decoded = (try? JSONDecoder().decode(
            [StaffAddress].self, from: Data(json.utf8),
        )) ?? []
        return Set(decoded)
    }

    private static func decodeProgramOverrides(
        _ json: String,
    ) -> [StaffAddress: Int] {
        let triples = (try? JSONDecoder().decode(
            [[Int]].self, from: Data(json.utf8),
        )) ?? []
        var result: [StaffAddress: Int] = [:]
        for triple in triples where triple.count == 3 {
            let address = StaffAddress(
                partIndex: triple[0], staffIndexInPart: triple[1],
            )
            result[address] = triple[2]
        }
        return result
    }

    private static func decodeVolumeOverrides(
        _ json: String,
    ) -> [StaffAddress: Double] {
        let triples = (try? JSONDecoder().decode(
            [[Double]].self, from: Data(json.utf8),
        )) ?? []
        var result: [StaffAddress: Double] = [:]
        for triple in triples where triple.count == 3 {
            let address = StaffAddress(
                partIndex: Int(triple[0]),
                staffIndexInPart: Int(triple[1]),
            )
            result[address] = triple[2]
        }
        return result
    }

    private static func decodeClefOverrides(
        _ json: String,
    ) -> [StaffAddress: String] {
        struct ClefTripleRow: Decodable {
            let partIndex: Int
            let staffIndexInPart: Int
            let rawType: String
        }
        let rows = (try? JSONDecoder().decode(
            [ClefTripleRow].self, from: Data(json.utf8),
        )) ?? []
        var result: [StaffAddress: String] = [:]
        for row in rows {
            let address = StaffAddress(
                partIndex: row.partIndex,
                staffIndexInPart: row.staffIndexInPart,
            )
            result[address] = row.rawType
        }
        return result
    }

    private static func encodeTriple(address: StaffAddress, program: Int) -> [Int] {
        [address.partIndex, address.staffIndexInPart, program]
    }

    private static func encodeVolumeTriple(address: StaffAddress, volume: Double) -> [Double] {
        [Double(address.partIndex), Double(address.staffIndexInPart), volume]
    }

    private static func encodeClefTriple(
        address: StaffAddress, rawType: String,
    ) -> ClefTripleEncoded {
        ClefTripleEncoded(
            partIndex: address.partIndex,
            staffIndexInPart: address.staffIndexInPart,
            rawType: rawType,
        )
    }

    private struct ClefTripleEncoded: Encodable {
        let partIndex: Int
        let staffIndexInPart: Int
        let rawType: String
    }
}
