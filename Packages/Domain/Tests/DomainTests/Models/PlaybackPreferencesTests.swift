@testable import Domain
import Foundation
import Testing

struct ChordPathTests {
    @Test func equatable() {
        let a = ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 2)
        let b = ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 2)
        let c = ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 3)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func `round trips through codable`() throws {
        let path = ChordPath(systemIndex: 1, measureIndex: 2, voiceIndex: 3, chordIndex: 4)
        let data = try JSONEncoder().encode(path)
        let decoded = try JSONDecoder().decode(ChordPath.self, from: data)
        #expect(decoded == path)
    }
}

struct StripMixerStateTests {
    @Test func `volume is clamped to unit interval`() {
        let state = StripMixerState(strip: MixerStripID(partIndex: 0, instrumentOrdinal: 0), volume: 1.5, gmProgram: 0)
        #expect(state.volume == 1)
        let state2 = StripMixerState(
            strip: MixerStripID(partIndex: 0, instrumentOrdinal: 0), volume: -0.1, gmProgram: 0,
        )
        #expect(state2.volume == 0)
    }

    @Test func `gm program is clamped to 0 through 127`() {
        let state = StripMixerState(
            strip: MixerStripID(partIndex: 0, instrumentOrdinal: 0), volume: 1, gmProgram: 200,
        )
        #expect(state.gmProgram == 127)
        let state2 = StripMixerState(
            strip: MixerStripID(partIndex: 0, instrumentOrdinal: 0), volume: 1, gmProgram: -1,
        )
        #expect(state2.gmProgram == 0)
    }
}

struct ABRepeatRangeTests {
    @Test func `range keeps both endpoints`() {
        let start = ChordPath(systemIndex: 0, measureIndex: 0, voiceIndex: 0, chordIndex: 0)
        let end = ChordPath(systemIndex: 1, measureIndex: 4, voiceIndex: 0, chordIndex: 2)
        let range = ABRepeatRange(start: start, end: end)
        #expect(range.start == start)
        #expect(range.end == end)
    }
}

struct PlaybackPreferencesTests {
    /// Both fields are independently optional because volume and program are separate override dictionaries: a
    /// strip can carry one and not the other. A non-optional `gmProgram` would need a filler, and the obvious
    /// one — 0 — is Acoustic Grand Piano, so saving a volume would silently retune the strip.
    @Test func `a strip state can carry a volume with no program`() {
        let state = StripMixerState(
            strip: MixerStripID(partIndex: 0, instrumentOrdinal: 0), volume: 0.4, gmProgram: nil,
        )

        #expect(state.volume == 0.4)
        #expect(state.gmProgram == nil)
    }

    @Test func `a strip state clamps the values it does carry`() {
        let state = StripMixerState(
            strip: MixerStripID(partIndex: 0, instrumentOrdinal: 0), volume: 3, gmProgram: 999,
        )

        #expect(state.volume == 1)
        #expect(state.gmProgram == 127)
    }

    @Test func `tempo multiplier is clamped to half through two`() {
        let prefs = PlaybackPreferences(
            id: PlaybackPreferencesID(),
            scoreItemID: ScoreItemID(),
            perStrip: [],
            tempoMultiplier: 5.0,
            abRepeat: nil,
        )
        #expect(prefs.tempoMultiplier == 2.0)
        let prefs2 = PlaybackPreferences(
            id: PlaybackPreferencesID(),
            scoreItemID: ScoreItemID(),
            perStrip: [],
            tempoMultiplier: 0.1,
            abRepeat: nil,
        )
        #expect(prefs2.tempoMultiplier == 0.5)
    }

    @Test func roundTripsThroughCodable() throws {
        let mixer = StripMixerState(strip: MixerStripID(partIndex: 0, instrumentOrdinal: 0), volume: 0.8, gmProgram: 4)
        let prefs = PlaybackPreferences(
            id: PlaybackPreferencesID(),
            scoreItemID: ScoreItemID(),
            perStrip: [mixer],
            tempoMultiplier: 1.0,
            abRepeat: ABRepeatRange(
                start: ChordPath(systemIndex: 0, measureIndex: 0, voiceIndex: 0, chordIndex: 0),
                end: ChordPath(systemIndex: 0, measureIndex: 4, voiceIndex: 0, chordIndex: 0),
            ),
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(PlaybackPreferences.self, from: data)
        #expect(decoded == prefs)
    }
}
