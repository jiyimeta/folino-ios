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
}
