import Foundation
import GRDB

extension AppMigrations {
    // MARK: - v17

    /// Re-keys the two audio-override columns from staff to mixer strip. Both hold rows of
    /// `[partIndex, staffIndexInPart, value]`, and a strip key encodes with the same two-integer shape, so this
    /// rewrites contents rather than the table: keep each part's first entry, drop the rest.
    ///
    /// A grand staff's two rows always drove one channel, so the dropped entries never had an independent sound;
    /// the kept one is what the mixer displayed on the part's first row. Program overrides lose nothing at all —
    /// the Reader has only ever written them for every staff of a part at once.
    ///
    /// Malformed JSON is replaced with `[]` rather than throwing: the record decoders already treat an
    /// unreadable column as "no overrides", and a migration that fails the whole open would be stricter than the
    /// app that reads it.
    static func migrateV17(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
        SELECT score_item_id, staff_program_overrides, staff_volume_overrides FROM reader_preferences
        """)
        for row in rows {
            let scoreItemID: String = row["score_item_id"]
            let programs = collapsingToFirstStaff(row["staff_program_overrides"])
            let volumes = collapsingToFirstStaff(row["staff_volume_overrides"])
            try db.execute(sql: """
            UPDATE reader_preferences
            SET staff_program_overrides = ?, staff_volume_overrides = ?
            WHERE score_item_id = ?
            """, arguments: [programs, volumes, scoreItemID])
        }
    }

    /// `[[part, staff, value], …]` with every `staff != 0` row removed, re-encoded. Returns `"[]"` for anything
    /// that does not decode as that shape.
    private static func collapsingToFirstStaff(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[Double]]
        else { return "[]" }
        let kept = rows.filter { $0.count == 3 && $0[1] == 0 }
        guard let out = try? JSONSerialization.data(withJSONObject: kept),
              let string = String(data: out, encoding: .utf8)
        else { return "[]" }
        return string
    }
}
