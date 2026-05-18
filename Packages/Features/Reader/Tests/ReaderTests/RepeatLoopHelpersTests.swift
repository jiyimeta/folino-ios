import Domain
@testable import Reader
import SheetMusicCore
import Testing

struct RepeatLoopHelpersTests {
    /// One quarter-note element used to populate measure fixtures. `VoiceElement.rest(duration:)` is sugar for
    /// `.chord(Chord(duration: ..., notes: []))`, so the fixture is composed of `.chord(_)` elements — what
    /// `snapMeasureEnd` matches.
    private static func element() -> VoiceElement {
        .rest(duration: .quarter)
    }

    /// 3-measure score, voice 0 has 2 elements, 3 elements, 1 element.
    private static func makeScore() -> Score {
        let m0 = Measure(voices: [Voice(elements: [element(), element()])])
        let m1 = Measure(voices: [Voice(elements: [element(), element(), element()])])
        let m2 = Measure(voices: [Voice(elements: [element()])])
        let staff = Staff(measures: [m0, m1, m2])
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [staff],
        )
        return Score(division: 480, parts: [part])
    }

    @Test func `measure index of beat cursor returns its field`() {
        let cursor = ScoreCursor.beat(measureIndex: 4, tickInMeasure: 240)
        #expect(measureIndex(of: cursor) == 4)
    }

    @Test func `measure index of item cursor reads it directly from the ID`() {
        let staffAddress = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let restID = RestID(
            staff: staffAddress, measureIndex: 7, voiceIndex: 0, elementIndex: 0,
        )
        let cursor = ScoreCursor.item(.rest(restID))
        #expect(measureIndex(of: cursor) == 7)
    }

    @Test func `snap measure head produces first chord in measure`() {
        let score = Self.makeScore()
        let head = snapMeasureHead(measureIndex: 1, in: score)
        #expect(head.measureIndex == 1)
        #expect(head.voiceIndex == 0)
        #expect(head.chordIndex == 0)
    }

    @Test func `snap measure end produces last chord in measure`() {
        let score = Self.makeScore()
        let end = snapMeasureEnd(measureIndex: 1, in: score)
        #expect(end?.measureIndex == 1)
        #expect(end?.voiceIndex == 0)
        // m1 has 3 elements -> last index is 2.
        #expect(end?.chordIndex == 2)
    }

    @Test func `snap measure end is nil for empty measure`() {
        let emptyMeasure = Measure(voices: [Voice(elements: [])])
        let staff = Staff(measures: [emptyMeasure])
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [staff],
        )
        let score = Score(division: 480, parts: [part])
        #expect(snapMeasureEnd(measureIndex: 0, in: score) == nil)
    }

    @Test func `score full range spans first chord of measure 0 to last chord of final measure`() {
        let score = Self.makeScore()
        let range = scoreFullRange(in: score)
        #expect(range?.start.measureIndex == 0)
        #expect(range?.end.measureIndex == 2)
        // m0 starts at element 0; m2 has 1 element -> last index is 0.
        #expect(range?.start.chordIndex == 0)
        #expect(range?.end.chordIndex == 0)
    }

    @Test func `normalize swaps range when start is after end`() {
        let early = ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0)
        let late = ChordPath(systemIndex: 0, measureIndex: 5, voiceIndex: 0, chordIndex: 1)
        let inverted = ABRepeatRange(start: late, end: early)
        let normalized = normalize(inverted)
        #expect(normalized.start == early)
        #expect(normalized.end == late)
    }
}
