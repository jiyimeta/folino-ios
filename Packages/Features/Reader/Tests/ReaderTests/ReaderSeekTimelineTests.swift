import Foundation
@testable import Reader
import SheetMusicCore
import Testing

/// `ReaderSeekTimeline` precomputes the per-measure timing that `Score.seconds(at:)` derives from scratch on every
/// call, so the playhead can be placed without walking the score on every cursor tick. That only holds up if the
/// table agrees with the engine's own arithmetic — which is what these check.
struct ReaderSeekTimelineTests {
    /// `count` 4/4 measures, division 480. Optional per-measure quarter-BPM via tempo markings in `systemMeasures`.
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

    @Test func `total duration matches the engine, tempo changes and all`() {
        let score = Self.score(measures: 4, tempos: [0: 120, 2: 60])
        let timeline = ReaderSeekTimeline(score: score)
        #expect(abs(timeline.durationSeconds - score.notatedDurationSeconds) < 1e-9)
    }

    @Test func `the placed fraction matches seconds at, measure by measure and within them`() {
        let score = Self.score(measures: 4, tempos: [0: 90, 2: 140])
        let timeline = ReaderSeekTimeline(score: score)
        let total = score.notatedDurationSeconds

        for measure in 0 ..< 4 {
            for tick in [0, 480, 960, 1440, 1920] {
                let cursor = ScoreCursor.beat(measureIndex: measure, tickInMeasure: tick)
                let expected = score.seconds(at: cursor) / total
                let placed = timeline.fraction(measureIndex: measure, tickInMeasure: tick)
                #expect(abs(placed - expected) < 1e-9, "measure \(measure), tick \(tick)")
            }
        }
    }

    @Test func `a pickup measure is as short in the table as it is in the score`() {
        // Measure 0 is a 1/4 pickup (0.5s @120 BPM); measure 1 is a full 4/4 bar (2.0s).
        let measures = [Measure(voices: [], actualLength: Fraction(numerator: 1, denominator: 4)), Measure(voices: [])]
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: measures)],
        )
        let score = Score(
            division: 480,
            parts: [part],
            systemMeasures: [
                SystemMeasure(elements: [
                    PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2.0))),
                ]),
                SystemMeasure(),
            ],
            metaTags: [:],
        )
        let timeline = ReaderSeekTimeline(score: score)
        #expect(abs(timeline.durationSeconds - 2.5) < 1e-9)
        #expect(abs(timeline.fraction(measureIndex: 1, tickInMeasure: 0) - 0.5 / 2.5) < 1e-9)
    }

    @Test func `the ends of the timeline are exactly the ends of the bar`() {
        let timeline = ReaderSeekTimeline(score: Self.score(measures: 2, tempos: [0: 120]))
        #expect(timeline.fraction(measureIndex: 0, tickInMeasure: 0) == 0)
        #expect(timeline.fraction(measureIndex: 1, tickInMeasure: 1920) == 1)
    }

    @Test func `an out-of-range cursor is clamped rather than trapped`() {
        let timeline = ReaderSeekTimeline(score: Self.score(measures: 2, tempos: [0: 120]))
        #expect(timeline.fraction(measureIndex: -3, tickInMeasure: -100) == 0)
        #expect(timeline.fraction(measureIndex: 99, tickInMeasure: 99999) == 1)
    }

    @Test func `an empty score places everything at the start`() {
        let timeline = ReaderSeekTimeline(score: Score(division: 480, parts: [], systemMeasures: [], metaTags: [:]))
        #expect(timeline.durationSeconds == 0)
        #expect(timeline.marks.isEmpty)
        #expect(timeline.fraction(measureIndex: 0, tickInMeasure: 0) == 0)
        #expect(timeline.fraction(measureIndex: 5, tickInMeasure: 500) == 0)
    }

    @Test func `the empty timeline is inert`() {
        #expect(ReaderSeekTimeline.empty.durationSeconds == 0)
        #expect(ReaderSeekTimeline.empty.fraction(measureIndex: 2, tickInMeasure: 240) == 0)
    }
}
