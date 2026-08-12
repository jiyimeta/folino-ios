import Domain
import Foundation
import Testing

/// The Android JSON-blob store has no migration runner, so the Codable layer carries the v16 conversion: a blob
/// without `schemaVersion` is legacy and its stored defaults are reclassified as untouched, exactly once in effect —
/// every re-encode stamps `schemaVersion: 3`, after which present values are authoritative.
struct ReaderPreferencesCodableVersionTests {
    private let scoreID = ScoreItemID()

    /// Builds legacy-blob JSON: encode a modern value, then strip `schemaVersion` and force the given raw fields.
    private func legacyJSON(overriding fields: [String: Any]) throws -> Data {
        let base = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        let data = try JSONEncoder().encode(base)
        var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "schemaVersion")
        dict.removeValue(forKey: "authoredHiddenStaves")
        for (key, value) in fields {
            dict[key] = value
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    @Test func `legacy blob normalizes stored defaults to nil`() throws {
        let data = try legacyJSON(overriding: [
            "staffSize": 14, "honorLayoutBreaks": true, "masterVolume": 1.0, "transposeSemitones": 0,
        ])
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.staffSize == nil)
        #expect(decoded.honorLayoutBreaks == nil)
        #expect(decoded.masterVolume == nil)
        #expect(decoded.transposeSemitones == nil)
    }

    @Test func `legacy blob keeps non-default values`() throws {
        let data = try legacyJSON(overriding: [
            "staffSize": 18, "honorLayoutBreaks": false, "masterVolume": 1.5, "transposeSemitones": -3,
        ])
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.staffSize == 18)
        #expect(decoded.honorLayoutBreaks == false)
        #expect(decoded.masterVolume == 1.5)
        #expect(decoded.transposeSemitones == -3)
    }

    @Test func `legacy blob seeds authored hidden from hidden staves`() throws {
        let hidden = [[1, 0]]
        let data = try legacyJSON(overriding: ["hiddenStaves": hidden, "staffSize": 14])
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.authoredHiddenStaves == decoded.hiddenStaves)
        #expect(!decoded.hiddenStaves.isEmpty)
    }

    @Test func `v3 blob keeps an explicit default value as some`() throws {
        let original = ReaderPreferences(
            scoreItemID: scoreID, staffSize: 14, hiddenStaves: [],
            honorLayoutBreaks: true, masterVolume: 1.0, transposeSemitones: 0,
        )
        let decoded = try JSONDecoder().decode(
            ReaderPreferences.self, from: JSONEncoder().encode(original),
        )
        #expect(decoded.staffSize == 14)
        #expect(decoded.honorLayoutBreaks == true)
        #expect(decoded.masterVolume == 1.0)
        #expect(decoded.transposeSemitones == 0)
    }

    @Test func `v3 blob round-trips nil as nil`() throws {
        let original = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        let decoded = try JSONDecoder().decode(
            ReaderPreferences.self, from: JSONEncoder().encode(original),
        )
        #expect(decoded.staffSize == nil)
        #expect(decoded.honorLayoutBreaks == nil)
        #expect(decoded.masterVolume == nil)
        #expect(decoded.transposeSemitones == nil)
        #expect(decoded == original)
    }

    /// The conversion is one-time *in effect*: the first decode of a legacy blob is followed by a re-encode that
    /// stamps `schemaVersion`, so a user who afterwards re-chooses a default value is never collapsed back to
    /// untouched. Without the marker this would be a per-read conversion that re-runs forever.
    @Test func `re-encoding a legacy blob stamps the version so the conversion cannot re-run`() throws {
        let legacy = try legacyJSON(overriding: ["staffSize": 18])
        var migrated = try JSONDecoder().decode(ReaderPreferences.self, from: legacy)
        // The user now explicitly re-chooses every default.
        migrated.staffSize = 14
        migrated.honorLayoutBreaks = true
        migrated.masterVolume = 1.0
        migrated.transposeSemitones = 0

        let reDecoded = try JSONDecoder().decode(
            ReaderPreferences.self, from: JSONEncoder().encode(migrated),
        )
        #expect(reDecoded.staffSize == 14)
        #expect(reDecoded.honorLayoutBreaks == true)
        #expect(reDecoded.masterVolume == 1.0)
        #expect(reDecoded.transposeSemitones == 0)
        #expect(reDecoded == migrated)
    }

    @Test func `every encode stamps the current schema version`() throws {
        let data = try JSONEncoder().encode(ReaderPreferences(scoreItemID: scoreID, hiddenStaves: []))
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict["schemaVersion"] as? Int == 3)
    }

    /// A v3 blob is authoritative about provenance: an absent `authoredHiddenStaves` means the score authored nothing
    /// hidden, so it must NOT be back-seeded from `hiddenStaves` the way a legacy blob is.
    @Test func `v3 blob does not seed authored hidden from hidden staves`() throws {
        let base = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        var dict = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any],
        )
        dict.removeValue(forKey: "authoredHiddenStaves")
        dict["hiddenStaves"] = [[1, 0]]
        let data = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.hiddenStaves.count == 1)
        #expect(decoded.authoredHiddenStaves.isEmpty)
    }
}
