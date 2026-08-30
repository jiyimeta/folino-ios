@testable import EditorCore
import SheetMusicCore
import Testing

/// The caret as a column (drum note entry's §5.4): where ← / → may stop, and which voice a write lands in.
///
/// The gate for this behavior is next door and not in this file: `EditorViewModelInputTests` and the navigation
/// suites must pass UNEDITED, because on a single-voice staff — every score in them — a column caret and a
/// voice-bound one are indistinguishable. What is asserted here is only the part that is new.
@Suite("The column caret")
struct ColumnCaretTests {
    private static let staff = EditorCoreFixtures.staff0

    /// One 4/4 bar, two voices: voice 0 is four quarter rests, voice 1 is a half rest then two quarters. Their
    /// onsets agree at 0 and 960 and disagree at 480 (voice 0 only) and 1440 (both).
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

    /// One 4/4 bar holding nothing but a measure rest — the bar → could not enter before the column caret, since a
    /// measure rest has exactly one onset.
    private static func emptyBar() -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .measure),
        ])
        let staffValue = Staff(measures: [Measure(voices: [voice])])
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staffValue])
        return Score(division: 480, parts: [part])
    }

    private static func slot(voice: Int, element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: voice, elementIndex: element)
    }

    private static func rest(voice: Int, element: Int) -> SheetMusicCore.ScoreItemID {
        .rest(RestID(staff: staff, measureIndex: 0, voiceIndex: voice, elementIndex: element))
    }

    @Test
    func `on a single-voice staff stepping lands exactly where it always did`() {
        let core = EditorCoreFixtures.makeCore()
        core.beginSession(score: EditorCoreFixtures.fourQuarterRests())
        core.select(.rest(EditorCoreFixtures.restID(element: 1)))

        core.selectNextElement()

        // Element 2, the next quarter rest — the answer the voice-bound walk gave, pinned literally so a column
        // path that moved it would fail here rather than somewhere far away.
        #expect(core.caretItem == .rest(EditorCoreFixtures.restID(element: 2)))
        #expect(core.selectedItem == core.caretItem)
    }

    @Test
    func `stepping forward stops at an onset only the other voice has`() {
        let core = EditorCoreFixtures.makeCore()
        core.beginSession(score: Self.twoVoiceBar())
        // Voice 1's opening half rest. The next onset in voice 1 alone is 960, but voice 0 has one at 480.
        core.select(Self.rest(voice: 1, element: 0))

        core.selectNextElement()

        #expect(core.caretColumn == ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 480))
        // Drawn on the voice that actually STARTS something there — voice 0's second quarter — not on the half
        // rest voice 1 is halfway through. Drawing it on the slot the column runs through leaves the marker
        // looking as though it never moved, and makes the next → read as a skipped beat (QA, 2026-08-30).
        #expect(core.caretItem == Self.rest(voice: 0, element: 2))
    }

    @Test
    func `stepping forward crosses an empty bar by the armed duration`() {
        let core = EditorCoreFixtures.makeCore()
        core.beginSession(score: Self.emptyBar())
        core.select(Self.rest(voice: 0, element: 1))
        core.setDuration(.quarter)

        var ticks: [Int] = []
        for _ in 0 ..< 3 {
            core.selectNextElement()
            ticks.append(core.caretColumn?.tick ?? -1)
        }

        #expect(ticks == [480, 960, 1440])
    }

    @Test
    func `a write goes to the active voice, not the caret's own`() {
        let core = EditorCoreFixtures.makeCore()
        core.beginSession(score: Self.twoVoiceBar())
        // Caret placed from voice 0's second quarter — tick 480 — while the pad has voice 2 (index 1) selected.
        core.select(Self.rest(voice: 0, element: 2))
        core.activeVoice = 1
        core.setDuration(.quarter)

        core.inputPitch(letter: "c")

        // Voice 1 was halfway through its half rest at 480, so the write splits it and lands in the second piece —
        // one undo step, and voice 0's own slot is untouched.
        let voice1 = core.score?.parts[0].staves[0].measures[0].voices[1]
        #expect(voice1?.elements.count == 4)
        guard case let .chord(written)? = voice1?.elements[1] else { Issue.record("expected a chord"); return }
        #expect(written.notes.first?.pitch == 60)
        guard case let .chord(voice0Slot)? = core.score?[Self.slot(voice: 0, element: 2)] else {
            Issue.record("expected voice 0's slot to still be there"); return
        }
        #expect(voice0Slot.notes.isEmpty)
    }

    /// The split is its own edit, so undoing a split write takes two steps: the note, then the rest going back
    /// together. See `writeTarget`'s doc for why the pitched path does not compose them — the drum key, whose
    /// pitch is literal, does (§5.5).
    @Test
    func `a split write undoes in two steps`() {
        let core = EditorCoreFixtures.makeCore()
        core.beginSession(score: Self.twoVoiceBar())
        let before = core.score
        core.select(Self.rest(voice: 0, element: 2))
        core.activeVoice = 1
        core.setDuration(.quarter)

        core.inputPitch(letter: "c")
        core.undo()
        #expect(core.score != before)

        core.undo()
        #expect(core.score == before)
    }

    @Test
    func `a write into a voice the measure does not have is refused`() {
        let core = EditorCoreFixtures.makeCore()
        core.beginSession(score: EditorCoreFixtures.fourQuarterRests())
        let before = core.score
        core.select(.rest(EditorCoreFixtures.restID(element: 1)))
        core.activeVoice = 1
        core.setDuration(.quarter)

        core.inputPitch(letter: "c")

        // Growing a staff a second voice is the drum key's job, which knows which voice its instrument wants.
        #expect(core.score == before)
    }
}
