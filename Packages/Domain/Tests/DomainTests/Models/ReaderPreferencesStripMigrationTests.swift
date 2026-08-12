import Domain
import Foundation
import Testing

/// Android persists `ReaderPreferences` through this Codable representation, not through GRDB, so the SQL
/// migration never reaches it. The schema version is what tells a stored `[partIndex, staffIndexInPart]` key from
/// a `[partIndex, instrumentOrdinal]` one, and a blob written before version 3 gets the same collapse the SQL
/// migration performs: keep the part's first entry, drop the rest.
@Suite("ReaderPreferences strip migration")
struct ReaderPreferencesStripMigrationTests {
    /// `ReaderPreferencesID` / `ScoreItemID` are plain `{rawValue: UUID}` wrappers with synthesized `Codable`, so they
    /// decode from a keyed object, not a bare string. `volumeRows` is the raw JSON for `staffVolumeOverrides`: Swift's
    /// synthesized `Dictionary` encoding for a non-`String`/`Int` key is a FLAT array alternating key then value —
    /// `[[p,s], value, [p,s], value, ...]` — never a row that merges the key and value into one array, because each
    /// key already encodes itself as a nested 2-element array via `StaffAddress`/`MixerStripID`'s own `Codable`.
    private func blob(schemaVersion: Int?, volumeRows: String) -> Data {
        let version = schemaVersion.map { "\"schemaVersion\":\($0)," } ?? ""
        return Data("""
        {\(version)"id":{"rawValue":"11111111-1111-1111-1111-111111111111"},\
        "scoreItemID":{"rawValue":"22222222-2222-2222-2222-222222222222"},\
        "hiddenStaves":[],"authoredHiddenStaves":[],"staffProgramOverrides":[],\
        "staffVolumeOverrides":\(volumeRows),"staffClefOverrides":[],\
        "repeatMode":"off","hasSeededAuthoredVisibility":true}
        """.utf8)
    }

    @Test func `a pre-v3 blob keeps only each part's first staff`() throws {
        let data = blob(schemaVersion: 2, volumeRows: "[[0,0],0.25,[0,1],0.75,[1,0],0.5]")

        let prefs = try JSONDecoder().decode(ReaderPreferences.self, from: data)

        #expect(prefs.stripVolumeOverrides == [
            MixerStripID(partIndex: 0, instrumentOrdinal: 0): 0.25,
            MixerStripID(partIndex: 1, instrumentOrdinal: 0): 0.5,
        ])
    }

    @Test func `a v3 blob is taken as written`() throws {
        let data = blob(schemaVersion: 3, volumeRows: "[[0,0],0.25,[0,1],0.75]")

        let prefs = try JSONDecoder().decode(ReaderPreferences.self, from: data)

        // Ordinal 1 is a real second strip at v3 — an instrument-change part — and must survive.
        #expect(prefs.stripVolumeOverrides.count == 2)
        #expect(prefs.stripVolumeOverrides[MixerStripID(partIndex: 0, instrumentOrdinal: 1)] == 0.75)
    }

    @Test func `a legacy blob with no version is collapsed too`() throws {
        let data = blob(schemaVersion: nil, volumeRows: "[[0,0],0.25,[0,1],0.75]")

        let prefs = try JSONDecoder().decode(ReaderPreferences.self, from: data)

        #expect(prefs.stripVolumeOverrides.count == 1)
    }
}
