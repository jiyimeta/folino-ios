import Foundation
@testable import Reader
import SheetMusicCore
import Testing

struct ScoreSeekTimeTests {
    /// `count` 4/4 measures, division 480. Optional per-measure quarter-BPM via tempo markings
    /// in `systemMeasures` (beatsPerSecond = bpm/60).
    private static func score(measures count: Int, tempos: [Int: Double] = [:]) -> Score {
        let staffMeasures = (0 ..< count).map { _ in Measure(voices: []) }
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: staffMeasures)],
        )
        let systemMeasures = (0 ..< count).map { i -> SystemMeasure in
            guard let bpm = tempos[i] else { return SystemMeasure() }
            return SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: bpm / 60))),
            ])
        }
        return Score(division: 480, parts: [part], systemMeasures: systemMeasures, metaTags: [:])
    }

    @Test func `constant 120 BPM — two 4_4 measures total four seconds`() {
        let s = Self.score(measures: 2, tempos: [0: 120])
        #expect(abs(s.notatedDurationSeconds - 4.0) < 0.0001)
    }

    @Test func `no tempo marking falls back to 120 BPM`() {
        let s = Self.score(measures: 2)
        #expect(abs(s.notatedDurationSeconds - 4.0) < 0.0001)
    }

    @Test func `seconds at measure start is cumulative`() {
        let s = Self.score(measures: 2, tempos: [0: 120])
        #expect(abs(s.seconds(at: .beat(measureIndex: 1, tickInMeasure: 0)) - 2.0) < 0.0001)
    }

    @Test func `seconds interpolates within a measure`() {
        let s = Self.score(measures: 2, tempos: [0: 120])
        // 4/4 at division 480 → 1920 ticks/measure; 480 ticks = 1 quarter = 0.25 of the bar = 0.5s.
        #expect(abs(s.seconds(at: .beat(measureIndex: 0, tickInMeasure: 480)) - 0.5) < 0.0001)
    }

    @Test func `tempo change lengthens the slower measure`() {
        // Measure 0 @120 (2s), measure 1 @60 (4s) → total 6s; measure 1 starts at 2s.
        let s = Self.score(measures: 2, tempos: [0: 120, 1: 60])
        #expect(abs(s.notatedDurationSeconds - 6.0) < 0.0001)
        #expect(abs(s.seconds(at: .beat(measureIndex: 1, tickInMeasure: 0)) - 2.0) < 0.0001)
        #expect(abs(s.seconds(at: .beat(measureIndex: 1, tickInMeasure: 960)) - 4.0) < 0.0001)
    }

    @Test func `cursor at seconds maps to measure and tick`() {
        let s = Self.score(measures: 2, tempos: [0: 120])
        #expect(s.cursor(atSeconds: 2.0) == .beat(measureIndex: 1, tickInMeasure: 0))
        #expect(s.cursor(atSeconds: 3.0) == .beat(measureIndex: 1, tickInMeasure: 960))
    }

    @Test func `cursor at seconds clamps to range`() {
        let s = Self.score(measures: 2, tempos: [0: 120])
        #expect(s.cursor(atSeconds: -5) == .beat(measureIndex: 0, tickInMeasure: 0))
        #expect(s.cursor(atSeconds: 99) == .beat(measureIndex: 1, tickInMeasure: 1920))
    }

    @Test func `round trips through seconds and back`() {
        let s = Self.score(measures: 3, tempos: [0: 90, 2: 140])
        let cursor = ScoreCursor.beat(measureIndex: 1, tickInMeasure: 720)
        let back = s.cursor(atSeconds: s.seconds(at: cursor))
        #expect(back == cursor)
    }

    @Test func `empty score is safe`() {
        let s = Score(division: 480, parts: [], systemMeasures: [], metaTags: [:])
        #expect(s.notatedDurationSeconds == 0)
        #expect(s.cursor(atSeconds: 1) == .beat(measureIndex: 0, tickInMeasure: 0))
    }
}
