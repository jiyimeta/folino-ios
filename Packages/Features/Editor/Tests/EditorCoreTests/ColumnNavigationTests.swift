@testable import EditorCore
import SheetMusicCore
import Testing

@Suite("ColumnNavigation")
struct ColumnNavigationTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    /// One 4/4 bar on one staff: voice 0 is four quarters, voice 1 is a half then two quarters — so the two voices
    /// share onsets at ticks 0 and 960 and disagree at 480 and 1440.
    private static func twoVoiceBar() -> Score {
        let voice0 = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter), .rest(duration: .quarter),
            .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        let voice1 = Voice(elements: [
            .rest(duration: .half), .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        let staffValue = Staff(measures: [Measure(voices: [voice0, voice1])])
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staffValue])
        return Score(division: 480, parts: [part])
    }

    private static func slot(voice: Int, element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: voice, elementIndex: element)
    }

    @Test
    func `a slot reports the column it sits in`() {
        let score = Self.twoVoiceBar()
        #expect(ColumnNavigation.column(of: Self.slot(voice: 0, element: 3), in: score)
            == ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 960))
        // Voice 1's half rest opens the bar, so its second element starts at the half-way tick too.
        #expect(ColumnNavigation.column(of: Self.slot(voice: 1, element: 1), in: score)
            == ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 960))
    }

    @Test
    func `a column resolves to the slot each voice has covering it`() {
        let score = Self.twoVoiceBar()
        let column = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 480)
        // Voice 0 has an onset exactly there; voice 1 is halfway through its opening half rest.
        #expect(ColumnNavigation.slot(inVoice: 0, at: column, in: score)?.slot == Self.slot(voice: 0, element: 2))
        #expect(ColumnNavigation.slot(inVoice: 0, at: column, in: score)?.tickWithinSlot == 0)
        #expect(ColumnNavigation.slot(inVoice: 1, at: column, in: score)?.slot == Self.slot(voice: 1, element: 0))
        #expect(ColumnNavigation.slot(inVoice: 1, at: column, in: score)?.tickWithinSlot == 480)
    }

    @Test
    func `a voice the measure does not have resolves to nothing`() {
        let score = Self.twoVoiceBar()
        let column = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 0)
        #expect(ColumnNavigation.slot(inVoice: 2, at: column, in: score) == nil)
    }

    @Test
    func `stepping forward stops at the next onset in ANY voice`() {
        let score = Self.twoVoiceBar()
        var column = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 0)
        var visited: [Int] = []
        while let next = ColumnNavigation.next(after: column, in: score, steppingBy: nil), next.measureIndex == 0 {
            visited.append(next.tick)
            column = next
        }
        // Voice 0's onsets are 0/480/960/1440 and voice 1's are 0/960/1440 — the union, in order.
        #expect(visited == [480, 960, 1440])
    }

    @Test
    func `stepping back walks the same union`() {
        let score = Self.twoVoiceBar()
        let column = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 960)
        #expect(ColumnNavigation.previous(before: column, in: score)?.tick == 480)
    }

    @Test
    func `stepping forward continues into the next measure`() {
        var score = Self.twoVoiceBar()
        score.parts[0].staves[0].measures.append(Measure(voices: [
            Voice(elements: [.rest(duration: .whole)]),
        ]))
        let last = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 1440)
        let next = ColumnNavigation.next(after: last, in: score, steppingBy: nil)
        #expect(next == ScoreColumn(staff: Self.staff, measureIndex: 1, tick: 0))
    }

    /// The rule that makes an empty bar enterable: a measure rest has ONE onset, at tick 0, so without this → would
    /// jump the whole bar and there would be no way to reach beat 2 of an empty measure at all.
    @Test
    func `with nothing ahead in the bar, stepping uses the armed duration`() {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .measure),
        ])
        let staffValue = Staff(measures: [Measure(voices: [voice])])
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staffValue])
        let score = Score(division: 480, parts: [part])

        let start = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 0)
        #expect(ColumnNavigation.next(after: start, in: score, steppingBy: .quarter)?.tick == 480)
        // And it stops at the barline rather than stepping past the bar's own length.
        let last = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 1440)
        #expect(ColumnNavigation.next(after: last, in: score, steppingBy: .quarter) == nil)
    }

    @Test
    func `the end of the staff has nowhere to go`() {
        let score = Self.twoVoiceBar()
        let last = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 1440)
        #expect(ColumnNavigation.next(after: last, in: score, steppingBy: nil) == nil)
        let first = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 0)
        #expect(ColumnNavigation.previous(before: first, in: score) == nil)
    }
}
