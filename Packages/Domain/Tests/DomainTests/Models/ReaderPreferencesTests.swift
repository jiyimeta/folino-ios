@testable import Domain
import Foundation
import Testing

@Suite struct ReaderPreferencesTests {
    @Test func staffSizeIsClampedToValidRange() {
        let tooSmall = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 1, hiddenStaffIDs: []
        )
        #expect(tooSmall.staffSize == 8)

        let tooBig = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 999, hiddenStaffIDs: []
        )
        #expect(tooBig.staffSize == 28)

        let inRange = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaffIDs: []
        )
        #expect(inRange.staffSize == 14)
    }

    @Test func defaultIDIsFresh() {
        let a = ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaffIDs: [])
        let b = ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaffIDs: [])
        #expect(a.id != b.id)
    }

    @Test func roundTripsThroughCodable() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(), staffSize: 12, hiddenStaffIDs: [1, 3]
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded == prefs)
    }
}
