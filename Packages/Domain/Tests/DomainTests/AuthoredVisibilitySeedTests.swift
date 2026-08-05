@testable import Domain
import Foundation
import SheetMusicCore
import Testing

struct AuthoredVisibilitySeedTests {
    private let itemID = ScoreItemID(rawValue: UUID())
    private let authored = StaffAddress(partIndex: 1, staffIndexInPart: 0)
    private let userHidden = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    /// Stands in for an authored set recorded by an earlier open that the score no longer matches.
    private let staleAuthored = StaffAddress(partIndex: 2, staffIndexInPart: 0)

    @Test func `fresh seed with no authored staves is not persisted`() {
        let (prefs, persist) = ReaderPreferences.reconcilingAuthoredHidden(
            stored: nil, authoredHiddenStaves: [], scoreItemID: itemID,
        )
        #expect(!persist)
        #expect(prefs.staffSize == nil)
        #expect(prefs.hasSeededAuthoredVisibility)
    }

    @Test func `fresh seed with authored staves persists and records provenance`() {
        let (prefs, persist) = ReaderPreferences.reconcilingAuthoredHidden(
            stored: nil, authoredHiddenStaves: [authored], scoreItemID: itemID,
        )
        #expect(persist)
        #expect(prefs.hiddenStaves == [authored])
        #expect(prefs.authoredHiddenStaves == [authored])
        #expect(prefs.hasSeededAuthoredVisibility)
        #expect(prefs.staffSize == nil)
    }

    @Test func `backfill records the authored set alongside the union`() {
        let stored = ReaderPreferences(
            scoreItemID: itemID, hiddenStaves: [userHidden], hasSeededAuthoredVisibility: false,
        )
        let (prefs, persist) = ReaderPreferences.reconcilingAuthoredHidden(
            stored: stored, authoredHiddenStaves: [authored], scoreItemID: itemID,
        )
        #expect(persist)
        #expect(prefs.hiddenStaves == [userHidden, authored])
        #expect(prefs.authoredHiddenStaves == [authored])
        #expect(prefs.hasSeededAuthoredVisibility)
    }

    @Test func `refresh updates a stale authored set without touching hidden staves`() {
        var stored = ReaderPreferences(
            scoreItemID: itemID, hiddenStaves: [], hasSeededAuthoredVisibility: true,
        )
        stored.authoredHiddenStaves = [staleAuthored]
        let (prefs, persist) = ReaderPreferences.reconcilingAuthoredHidden(
            stored: stored, authoredHiddenStaves: [authored], scoreItemID: itemID,
        )
        #expect(persist)
        #expect(prefs.hiddenStaves.isEmpty) // user reveal stays sticky
        #expect(prefs.authoredHiddenStaves == [authored])
    }

    @Test func `matching authored set returns stored unchanged with no persist`() {
        var stored = ReaderPreferences(
            scoreItemID: itemID, hiddenStaves: [authored], hasSeededAuthoredVisibility: true,
        )
        stored.authoredHiddenStaves = [authored]
        let (prefs, persist) = ReaderPreferences.reconcilingAuthoredHidden(
            stored: stored, authoredHiddenStaves: [authored], scoreItemID: itemID,
        )
        #expect(!persist)
        #expect(prefs == stored)
    }

    @Test func `no authored hidden leaves unseeded stored read only`() {
        let stored = ReaderPreferences(
            scoreItemID: itemID, staffSize: 14, hiddenStaves: [userHidden],
            hasSeededAuthoredVisibility: false,
        )
        let (prefs, persist) = ReaderPreferences.reconcilingAuthoredHidden(
            stored: stored, authoredHiddenStaves: [], scoreItemID: itemID,
        )
        #expect(!persist)
        #expect(prefs == stored)
    }
}
