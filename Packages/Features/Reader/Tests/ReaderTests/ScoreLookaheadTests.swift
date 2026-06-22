import Foundation
@testable import Reader
import SheetMusicCore
import Testing

struct ScoreLookaheadTests {
    /// `count` default (4/4, 1920-tick) measures at division 480.
    private static func score(measures count: Int) -> Score {
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: (0 ..< count).map { _ in Measure(voices: []) })],
        )
        let systemMeasures = (0 ..< count).map { _ in SystemMeasure() }
        return Score(division: 480, parts: [part], systemMeasures: systemMeasures, metaTags: [:])
    }

    @Test func `advances within a measure — two beats is 960 ticks`() {
        let s = Self.score(measures: 1)
        #expect(
            s.cursor(advancedByBeats: 2, from: .beat(measureIndex: 0, tickInMeasure: 0))
                == .beat(measureIndex: 0, tickInMeasure: 960),
        )
    }

    @Test func `crosses one measure boundary`() {
        let s = Self.score(measures: 2)
        #expect(
            s.cursor(advancedByBeats: 2, from: .beat(measureIndex: 0, tickInMeasure: 1440))
                == .beat(measureIndex: 1, tickInMeasure: 480),
        )
    }

    @Test func `advances across a full measure`() {
        let s = Self.score(measures: 2)
        #expect(
            s.cursor(advancedByBeats: 6, from: .beat(measureIndex: 0, tickInMeasure: 0))
                == .beat(measureIndex: 1, tickInMeasure: 960),
        )
    }

    @Test func `clamps to the final tick at end of score`() {
        let s = Self.score(measures: 2)
        #expect(
            s.cursor(advancedByBeats: 4, from: .beat(measureIndex: 1, tickInMeasure: 1440))
                == .beat(measureIndex: 1, tickInMeasure: 1920),
        )
    }

    @Test func `non-positive beats returns the input cursor`() {
        let s = Self.score(measures: 2)
        #expect(
            s.cursor(advancedByBeats: 0, from: .beat(measureIndex: 0, tickInMeasure: 480))
                == .beat(measureIndex: 0, tickInMeasure: 480),
        )
        #expect(
            s.cursor(advancedByBeats: -3, from: .beat(measureIndex: 0, tickInMeasure: 480))
                == .beat(measureIndex: 0, tickInMeasure: 480),
        )
    }

    @Test func `empty score returns the input cursor`() {
        let s = Score(division: 480, parts: [], systemMeasures: [], metaTags: [:])
        #expect(
            s.cursor(advancedByBeats: 2, from: .beat(measureIndex: 0, tickInMeasure: 0))
                == .beat(measureIndex: 0, tickInMeasure: 0),
        )
    }

    @Test func `accounts for a short pickup measure`() {
        // Measure 0 is a 1/4 pickup (480 ticks); measure 1 is full 4/4 (1920 ticks).
        let pickup = Fraction(numerator: 1, denominator: 4)
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: [Measure(voices: [], actualLength: pickup), Measure(voices: [])])],
        )
        let s = Score(
            division: 480,
            parts: [part],
            systemMeasures: [SystemMeasure(), SystemMeasure()],
            metaTags: [:],
        )
        // 2 beats = 960 ticks: 480 consumes the pickup, 480 spills into measure 1.
        #expect(
            s.cursor(advancedByBeats: 2, from: .beat(measureIndex: 0, tickInMeasure: 0))
                == .beat(measureIndex: 1, tickInMeasure: 480),
        )
    }
}
