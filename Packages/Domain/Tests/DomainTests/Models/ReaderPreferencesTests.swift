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
}
