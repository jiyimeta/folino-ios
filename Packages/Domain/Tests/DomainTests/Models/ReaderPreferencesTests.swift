@testable import Domain
import Foundation
import SheetMusicCore
import Testing

struct ReaderPreferencesTests {
    @Test func `staff size is clamped to valid range`() {
        let tooSmall = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 1, hiddenStaves: [],
        )
        #expect(tooSmall.staffSize == 8)

        let tooBig = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 999, hiddenStaves: [],
        )
        #expect(tooBig.staffSize == 28)

        let inRange = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [],
        )
        #expect(inRange.staffSize == 14)
    }

    @Test func `staff-bound overrides are detected and cleared, leaving sound-only settings alone`() {
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [address],
            authoredHiddenStaves: [address],
            staffClefOverrides: [address: "F"],
            tempoMultiplier: 1.5,
            masterVolume: 2.0,
            transposeSemitones: 3,
        )
        #expect(prefs.hasStaffBoundOverrides)

        let cleared = prefs.clearingStaffBoundOverrides()
        #expect(!cleared.hasStaffBoundOverrides)
        #expect(cleared.hiddenStaves.isEmpty)
        #expect(cleared.authoredHiddenStaves.isEmpty)
        #expect(cleared.staffClefOverrides.isEmpty)
        #expect(cleared.transposeSemitones == nil)
        #expect(cleared.staffSize == 14)
        #expect(cleared.tempoMultiplier == 1.5)
        #expect(cleared.masterVolume == 2.0)
    }

    @Test func `preferences with nothing staff-bound set report clean`() {
        let prefs = ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [])
        #expect(!prefs.hasStaffBoundOverrides)
    }

    @Test func `default ID is fresh`() {
        let a = ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [])
        let b = ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [])
        #expect(a.id != b.id)
    }

    @Test func `round trips through codable`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 12,
            hiddenStaves: [
                StaffAddress(partIndex: 0, staffIndexInPart: 1),
                StaffAddress(partIndex: 1, staffIndexInPart: 0),
            ],
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded == prefs)
    }

    @Test func `program overrides default to empty`() {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
        )
        #expect(prefs.staffProgramOverrides.isEmpty)
    }

    @Test func `program overrides are clamped to 0 through 127`() {
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let belowRange = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffProgramOverrides: [address: -5],
        )
        #expect(belowRange.staffProgramOverrides[address] == 0)

        let aboveRange = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffProgramOverrides: [address: 999],
        )
        #expect(aboveRange.staffProgramOverrides[address] == 127)
    }

    @Test func `program overrides round trip through codable`() throws {
        let address1 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let address2 = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffProgramOverrides: [address1: 6, address2: 40],
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.staffProgramOverrides == prefs.staffProgramOverrides)
    }

    @Test func `tempo multiplier defaults to nil`() {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
        )
        #expect(prefs.tempoMultiplier == nil)
    }

    @Test func `tempo multiplier is clamped to half through double`() {
        let tooSlow = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 0.1,
        )
        #expect(tooSlow.tempoMultiplier == 0.5)

        let tooFast = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 5.0,
        )
        #expect(tooFast.tempoMultiplier == 2.0)

        let inRange = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 0.75,
        )
        #expect(inRange.tempoMultiplier == 0.75)
    }

    @Test func `tempo multiplier nil round trips through codable`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.tempoMultiplier == nil)
    }

    @Test func `tempo multiplier round trips through codable`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 1.25,
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.tempoMultiplier == 1.25)
    }

    @Test func `staff volume overrides default to empty`() {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
        )
        #expect(prefs.staffVolumeOverrides.isEmpty)
    }

    @Test func `staff volume overrides are clamped to zero through one`() {
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let belowRange = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffVolumeOverrides: [address: -0.5],
        )
        #expect(belowRange.staffVolumeOverrides[address] == 0)

        let aboveRange = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffVolumeOverrides: [address: 2.0],
        )
        #expect(aboveRange.staffVolumeOverrides[address] == 1)

        let inRange = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffVolumeOverrides: [address: 0.42],
        )
        #expect(inRange.staffVolumeOverrides[address] == 0.42)
    }

    @Test func `staff volume overrides round trip through codable`() throws {
        let address1 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let address2 = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffVolumeOverrides: [address1: 0.25, address2: 0.8],
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.staffVolumeOverrides == prefs.staffVolumeOverrides)
    }

    @Test func `clef override round trips through codable`() throws {
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffClefOverrides: [address: "G8vb"],
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.staffClefOverrides == [address: "G8vb"])
    }

    @Test func `clef override decodes as empty when absent from JSON`() throws {
        // Hand-crafted JSON missing `staffClefOverrides` (legacy shape).
        let scoreID = ScoreItemID()
        let prefsID = ReaderPreferencesID()
        let json = """
        {
          "id": { "rawValue": "\(prefsID.rawValue.uuidString)" },
          "scoreItemID": { "rawValue": "\(scoreID.rawValue.uuidString)" },
          "staffSize": 14,
          "hiddenStaves": [],
          "staffProgramOverrides": [],
          "staffVolumeOverrides": []
        }
        """
        let decoded = try JSONDecoder().decode(
            ReaderPreferences.self, from: Data(json.utf8),
        )
        #expect(decoded.staffClefOverrides.isEmpty)
    }

    @Test func `clef override initializer drops unknown raw type`() {
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffClefOverrides: [address: "not-a-real-clef"],
        )
        #expect(prefs.staffClefOverrides.isEmpty)
    }

    @Test func `master volume is untouched by default and resolves to unity`() {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [],
        )
        #expect(prefs.masterVolume == nil)
        #expect(prefs.effectiveMasterVolume == 1.0)
    }

    @Test func `master volume is clamped to zero through three`() {
        let below = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [],
            masterVolume: -1.0,
        )
        #expect(below.masterVolume == 0)

        let above = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [],
            masterVolume: 9.0,
        )
        #expect(above.masterVolume == 3.0)

        let inRange = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [],
            masterVolume: 2.25,
        )
        #expect(inRange.masterVolume == 2.25)
    }

    @Test func `master volume round trips through codable`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [],
            masterVolume: 2.5,
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.masterVolume == 2.5)
    }

    @Test func `JSON without a master volume key decodes as untouched and resolves to unity`() throws {
        // An absent key means the user never set the field, so it decodes as `nil` and resolves to unity through
        // `effectiveMasterVolume` — no value is materialized on the way in.
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [], masterVolume: 2.5,
        )
        let encoded = try JSONEncoder().encode(prefs)
        let jsonObject = try JSONSerialization.jsonObject(with: encoded)
        var dict = try #require(jsonObject as? [String: Any])
        dict.removeValue(forKey: "masterVolume")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: stripped)
        #expect(decoded.masterVolume == nil)
        #expect(decoded.effectiveMasterVolume == 1.0)
    }

    @Test func `legacy JSON without tempo multiplier key decodes as nil`() throws {
        // Ensures additive-only schema change: rows persisted before tempoMultiplier landed must still load. We
        // synthesize the "legacy" shape by encoding the current struct and stripping the new key, so we don't have to
        // hand-write IDs whose encoded form is implementation-defined.
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
        )
        let encoded = try JSONEncoder().encode(prefs)
        let jsonObject = try JSONSerialization.jsonObject(with: encoded)
        var dict = try #require(jsonObject as? [String: Any])
        dict.removeValue(forKey: "tempoMultiplier")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: stripped)
        #expect(decoded.tempoMultiplier == nil)
        #expect(decoded.staffSize == 14)
    }

    @Test func `full field JSON round trip preserves everything`() throws {
        // The Android persistence blob relies on this exact `Codable` encoding. All values are chosen in-range so the
        // initializer's clamping/filtering is a no-op and the round-trip is exact equality.
        let original = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 17,
            hiddenStaves: [StaffAddress(partIndex: 0, staffIndexInPart: 1)],
            authoredHiddenStaves: [StaffAddress(partIndex: 1, staffIndexInPart: 1)],
            staffProgramOverrides: [StaffAddress(partIndex: 0, staffIndexInPart: 0): 40],
            staffVolumeOverrides: [StaffAddress(partIndex: 1, staffIndexInPart: 0): 0.5],
            staffClefOverrides: [StaffAddress(partIndex: 0, staffIndexInPart: 0): "F"],
            tempoMultiplier: 1.5,
            honorLayoutBreaks: false,
            repeatMode: .abLoop,
            abRepeat: ABRepeatRange(
                start: ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0),
                end: ChordPath(systemIndex: 1, measureIndex: 5, voiceIndex: 0, chordIndex: 0),
            ),
            masterVolume: 1.2,
            transposeSemitones: 3,
            a4ReferenceHz: 432,
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded == original)
    }
}
