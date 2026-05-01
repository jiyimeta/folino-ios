@testable import Domain
import Foundation
import Testing

@Suite struct ChordPathTests {
    @Test func equatable() {
        let a = ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 2)
        let b = ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 2)
        let c = ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 3)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func roundTripsThroughCodable() throws {
        let path = ChordPath(systemIndex: 1, measureIndex: 2, voiceIndex: 3, chordIndex: 4)
        let data = try JSONEncoder().encode(path)
        let decoded = try JSONDecoder().decode(ChordPath.self, from: data)
        #expect(decoded == path)
    }
}

@Suite struct StaffMixerStateTests {
    @Test func volumeIsClampedToUnitInterval() {
        let state = StaffMixerState(staffIndex: 0, volume: 1.5, isMuted: false, isSolo: false, gmBank: 0, gmProgram: 0)
        #expect(state.volume == 1)
        let state2 = StaffMixerState(
            staffIndex: 0, volume: -0.1, isMuted: false, isSolo: false, gmBank: 0, gmProgram: 0
        )
        #expect(state2.volume == 0)
    }

    @Test func gmProgramIsClampedTo0Through127() {
        let state = StaffMixerState(staffIndex: 0, volume: 1, isMuted: false, isSolo: false, gmBank: 0, gmProgram: 200)
        #expect(state.gmProgram == 127)
        let state2 = StaffMixerState(staffIndex: 0, volume: 1, isMuted: false, isSolo: false, gmBank: 0, gmProgram: -1)
        #expect(state2.gmProgram == 0)
    }
}

@Suite struct ABRepeatRangeTests {
    @Test func rangeKeepsBothEndpoints() {
        let start = ChordPath(systemIndex: 0, measureIndex: 0, voiceIndex: 0, chordIndex: 0)
        let end = ChordPath(systemIndex: 1, measureIndex: 4, voiceIndex: 0, chordIndex: 2)
        let range = ABRepeatRange(start: start, end: end)
        #expect(range.start == start)
        #expect(range.end == end)
    }
}

@Suite struct PlaybackPreferencesTests {
    @Test func tempoMultiplierIsClampedToHalfThroughTwo() {
        let prefs = PlaybackPreferences(
            id: PlaybackPreferencesID(),
            scoreItemID: ScoreItemID(),
            perStaff: [],
            tempoMultiplier: 5.0,
            abRepeat: nil
        )
        #expect(prefs.tempoMultiplier == 2.0)
        let prefs2 = PlaybackPreferences(
            id: PlaybackPreferencesID(),
            scoreItemID: ScoreItemID(),
            perStaff: [],
            tempoMultiplier: 0.1,
            abRepeat: nil
        )
        #expect(prefs2.tempoMultiplier == 0.5)
    }

    @Test func roundTripsThroughCodable() throws {
        let mixer = StaffMixerState(staffIndex: 0, volume: 0.8, isMuted: false, isSolo: true, gmBank: 0, gmProgram: 4)
        let prefs = PlaybackPreferences(
            id: PlaybackPreferencesID(),
            scoreItemID: ScoreItemID(),
            perStaff: [mixer],
            tempoMultiplier: 1.0,
            abRepeat: ABRepeatRange(
                start: ChordPath(systemIndex: 0, measureIndex: 0, voiceIndex: 0, chordIndex: 0),
                end: ChordPath(systemIndex: 0, measureIndex: 4, voiceIndex: 0, chordIndex: 0)
            )
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(PlaybackPreferences.self, from: data)
        #expect(decoded == prefs)
    }
}
