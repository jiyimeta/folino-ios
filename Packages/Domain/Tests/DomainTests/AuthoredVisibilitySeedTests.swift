@testable import Domain
import Foundation
import SheetMusicCore
import Testing

struct AuthoredVisibilitySeedTests {
    private let itemID = ScoreItemID(rawValue: UUID())
    private let authored = StaffAddress(partIndex: 1, staffIndexInPart: 0)
    private let userHidden = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    @Test func `seeds when no stored value`() {
        let (prefs, persist) = ReaderPreferences.reconcilingAuthoredHidden(
            stored: nil, authoredHiddenStaves: [authored],
            scoreItemID: itemID, defaultStaffSize: 14,
        )
        #expect(prefs.hiddenStaves == [authored])
        #expect(prefs.hasSeededAuthoredVisibility)
        #expect(persist)
    }

    @Test func `backfills unseeded stored unioned with user hidden`() {
        let stored = ReaderPreferences(
            scoreItemID: itemID, staffSize: 14, hiddenStaves: [userHidden],
            hasSeededAuthoredVisibility: false,
        )
        let (prefs, persist) = ReaderPreferences.reconcilingAuthoredHidden(
            stored: stored, authoredHiddenStaves: [authored],
            scoreItemID: itemID, defaultStaffSize: 14,
        )
        #expect(prefs.hiddenStaves == [userHidden, authored])
        #expect(prefs.hasSeededAuthoredVisibility)
        #expect(persist)
    }

    @Test func `leaves already seeded stored untouched`() {
        let stored = ReaderPreferences(
            scoreItemID: itemID, staffSize: 14, hiddenStaves: [],
            hasSeededAuthoredVisibility: true,
        )
        let (prefs, persist) = ReaderPreferences.reconcilingAuthoredHidden(
            stored: stored, authoredHiddenStaves: [authored],
            scoreItemID: itemID, defaultStaffSize: 14,
        )
        #expect(prefs.hiddenStaves.isEmpty)
        #expect(!persist)
    }

    @Test func `no authored hidden leaves unseeded stored read only`() {
        let stored = ReaderPreferences(
            scoreItemID: itemID, staffSize: 14, hiddenStaves: [userHidden],
            hasSeededAuthoredVisibility: false,
        )
        let (prefs, persist) = ReaderPreferences.reconcilingAuthoredHidden(
            stored: stored, authoredHiddenStaves: [],
            scoreItemID: itemID, defaultStaffSize: 14,
        )
        #expect(prefs.hiddenStaves == [userHidden])
        #expect(!persist)
    }
}
