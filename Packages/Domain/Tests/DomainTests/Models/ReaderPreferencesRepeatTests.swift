@testable import Domain
import Foundation
import SheetMusicCore
import Testing

struct ReaderPreferencesRepeatTests {
    private static func sampleScoreItemID() -> Domain.ScoreItemID {
        Domain.ScoreItemID()
    }

    @Test func `defaults repeat mode off and ab repeat nil`() {
        let prefs = ReaderPreferences(
            scoreItemID: Self.sampleScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
        )
        #expect(prefs.repeatMode == .off)
        #expect(prefs.abRepeat == nil)
    }

    @Test func `legacy JSON without repeat fields decodes with defaults`() throws {
        // Encode a current struct then strip the new keys to simulate a
        // record persisted before repeatMode / abRepeat landed — same
        // technique used for tempoMultiplier's back-compat test.
        let prefs = ReaderPreferences(
            scoreItemID: Self.sampleScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
        )
        let encoded = try JSONEncoder().encode(prefs)
        let jsonObject = try JSONSerialization.jsonObject(with: encoded)
        var dict = try #require(jsonObject as? [String: Any])
        dict.removeValue(forKey: "repeatMode")
        dict.removeValue(forKey: "abRepeat")
        let stripped = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: stripped)

        #expect(decoded.repeatMode == .off)
        #expect(decoded.abRepeat == nil)
    }

    @Test func `round trips through JSON with repeat fields set`() throws {
        let chord = ChordPath(systemIndex: 0, measureIndex: 4, voiceIndex: 0, chordIndex: 0)
        let endChord = ChordPath(systemIndex: 0, measureIndex: 8, voiceIndex: 0, chordIndex: 3)
        let prefs = ReaderPreferences(
            scoreItemID: Self.sampleScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            repeatMode: .abLoop,
            abRepeat: ABRepeatRange(start: chord, end: endChord),
        )

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)

        #expect(decoded.repeatMode == .abLoop)
        #expect(decoded.abRepeat?.start == chord)
        #expect(decoded.abRepeat?.end == endChord)
    }
}
