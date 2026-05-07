@testable import Domain
import Foundation
import SheetMusicCore
import Testing

@Suite struct ReaderPreferencesTests {
    @Test func staffSizeIsClampedToValidRange() {
        let tooSmall = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 1, hiddenStaves: []
        )
        #expect(tooSmall.staffSize == 8)

        let tooBig = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 999, hiddenStaves: []
        )
        #expect(tooBig.staffSize == 28)

        let inRange = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: []
        )
        #expect(inRange.staffSize == 14)
    }

    @Test func defaultIDIsFresh() {
        let a = ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [])
        let b = ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [])
        #expect(a.id != b.id)
    }

    @Test func roundTripsThroughCodable() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 12,
            hiddenStaves: [
                StaffAddress(partIndex: 0, staffIndexInPart: 1),
                StaffAddress(partIndex: 1, staffIndexInPart: 0),
            ]
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded == prefs)
    }

    @Test func programOverridesDefaultToEmpty() {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: []
        )
        #expect(prefs.staffProgramOverrides.isEmpty)
    }

    @Test func programOverridesAreClampedTo0Through127() {
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let belowRange = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffProgramOverrides: [address: -5]
        )
        #expect(belowRange.staffProgramOverrides[address] == 0)

        let aboveRange = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffProgramOverrides: [address: 999]
        )
        #expect(aboveRange.staffProgramOverrides[address] == 127)
    }

    @Test func programOverridesRoundTripThroughCodable() throws {
        let address1 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let address2 = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffProgramOverrides: [address1: 6, address2: 40]
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.staffProgramOverrides == prefs.staffProgramOverrides)
    }

    @Test func tempoMultiplierDefaultsToNil() {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: []
        )
        #expect(prefs.tempoMultiplier == nil)
    }

    @Test func tempoMultiplierIsClampedToHalfThroughDouble() {
        let tooSlow = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 0.1
        )
        #expect(tooSlow.tempoMultiplier == 0.5)

        let tooFast = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 5.0
        )
        #expect(tooFast.tempoMultiplier == 2.0)

        let inRange = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 0.75
        )
        #expect(inRange.tempoMultiplier == 0.75)
    }

    @Test func tempoMultiplierNilRoundTripsThroughCodable() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: []
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.tempoMultiplier == nil)
    }

    @Test func tempoMultiplierRoundTripsThroughCodable() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 1.25
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.tempoMultiplier == 1.25)
    }

    @Test func staffVolumeOverridesDefaultToEmpty() {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: []
        )
        #expect(prefs.staffVolumeOverrides.isEmpty)
    }

    @Test func staffVolumeOverridesAreClampedToZeroThroughOne() {
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let belowRange = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffVolumeOverrides: [address: -0.5]
        )
        #expect(belowRange.staffVolumeOverrides[address] == 0)

        let aboveRange = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffVolumeOverrides: [address: 2.0]
        )
        #expect(aboveRange.staffVolumeOverrides[address] == 1)

        let inRange = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffVolumeOverrides: [address: 0.42]
        )
        #expect(inRange.staffVolumeOverrides[address] == 0.42)
    }

    @Test func staffVolumeOverridesRoundTripThroughCodable() throws {
        let address1 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let address2 = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            staffVolumeOverrides: [address1: 0.25, address2: 0.8]
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.staffVolumeOverrides == prefs.staffVolumeOverrides)
    }

    @Test func legacyJSONWithoutTempoMultiplierKeyDecodesAsNil() throws {
        // Ensures additive-only schema change: rows persisted before
        // tempoMultiplier landed must still load. We synthesize the
        // "legacy" shape by encoding the current struct and stripping
        // the new key, so we don't have to hand-write IDs whose
        // encoded form is implementation-defined.
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: []
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
}
