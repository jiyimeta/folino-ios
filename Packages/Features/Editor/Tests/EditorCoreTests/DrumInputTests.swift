@testable import EditorCore
import SheetMusicCore
import Testing

/// Pressing a drum key (drum note entry's §5.1, §5.3, §5.5).
@Suite("Drum note entry")
struct DrumInputTests {
    private static let staff = EditorCoreFixtures.staff0

    /// One 4/4 bar on a percussion staff, voice 0 = four quarter rests. `kit` is what the part's own drumset knows;
    /// the default omits nothing the tests below need except where a test says otherwise.
    private static func drumScore(kit: [Int: Int] = GMPercussion.drumLineMap, voices: Int = 1) -> Score {
        let quarters: [VoiceElement] = [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter), .rest(duration: .quarter),
            .rest(duration: .quarter), .rest(duration: .quarter),
        ]
        let extra = Array(repeating: Voice(elements: [.rest(duration: .measure)]), count: voices - 1)
        let staffValue = Staff(
            staffType: GMPercussion.staffTypeName,
            group: GMPercussion.staffGroup,
            measures: [Measure(voices: [Voice(elements: quarters)] + extra)],
        )
        let part = Part(
            id: "1",
            instrument: Instrument(id: "drumset", useDrumset: true, drumLineMap: kit),
            staves: [staffValue],
        )
        return Score(division: 480, parts: [part])
    }

    /// One 4/4 bar on a percussion staff whose only voice holds a single bar-long rest — a bar nothing has been
    /// written into yet, which is what `Score.blank` hands a new drum score.
    private static func barRestDrumScore() -> Score {
        let barRest: [VoiceElement] = [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .measure),
        ]
        let staffValue = Staff(
            staffType: GMPercussion.staffTypeName,
            group: GMPercussion.staffGroup,
            measures: [Measure(voices: [Voice(elements: barRest)])],
        )
        let part = Part(
            id: "1",
            instrument: Instrument(id: "drumset", useDrumset: true, drumLineMap: GMPercussion.drumLineMap),
            staves: [staffValue],
        )
        return Score(division: 480, parts: [part])
    }

    private static func pitchedScore() -> Score {
        EditorCoreFixtures.fourQuarterRests()
    }

    private static func rest(voice: Int = 0, element: Int) -> SheetMusicCore.ScoreItemID {
        .rest(RestID(staff: staff, measureIndex: 0, voiceIndex: voice, elementIndex: element))
    }

    private static func slot(voice: Int = 0, element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: voice, elementIndex: element)
    }

    /// A GM key for `pitch`, optionally forced into `voice`. The GM table names every pitch these tests use, so a
    /// miss is a typo in the test rather than a case worth handling — it lands as a key that writes nothing.
    private static func key(_ pitch: Int, voice: Int? = nil) -> DrumPadKey {
        guard var key = DrumPadKey(gmPitch: pitch) else {
            return DrumPadKey(pitch: pitch, name: "", headType: nil, line: 0, voiceIndex: voice ?? 0)
        }
        if let voice {
            key.voiceIndex = voice
        }
        return key
    }

    private static func armedCore(_ score: Score, at element: Int = 1) -> EditorSessionCore {
        let core = EditorCoreFixtures.makeCore()
        core.beginSession(score: score)
        core.select(rest(element: element))
        core.setDuration(.quarter)
        return core
    }

    // MARK: - §5.1 which pad the score asks for

    @Test
    func `a pitched staff never asks for the drum pad`() {
        let core = Self.armedCore(Self.pitchedScore())
        #expect(!core.isDrumStaffActive)
    }

    @Test
    func `a percussion staff under the caret asks for it`() {
        let core = Self.armedCore(Self.drumScore())
        #expect(core.isDrumStaffActive)
    }

    // MARK: - §5.3 what is lit

    @Test
    func `an empty column lights nothing`() {
        let core = Self.armedCore(Self.drumScore())
        #expect(core.litDrumPitches.isEmpty)
    }

    @Test
    func `both hands light when they sound at the same tick`() {
        let core = Self.armedCore(Self.drumScore(voices: 2))
        core.pressDrumKey(Self.key(42, voice: 0))
        core.pressDrumKey(Self.key(36, voice: 1))

        #expect(core.litDrumPitches == [42, 36])
    }

    @Test
    func `a hit at another tick in the same bar does not light`() {
        let core = Self.armedCore(Self.drumScore())
        core.pressDrumKey(Self.key(42))
        core.selectNextElement()

        #expect(core.litDrumPitches.isEmpty)
    }

    // MARK: - §5.5 what a press does

    @Test
    func `a rest at the column becomes the instrument, with its notehead`() {
        let core = Self.armedCore(Self.drumScore())

        core.pressDrumKey(Self.key(42))

        guard case let .chord(chord)? = core.score?[Self.slot(element: 1)] else {
            Issue.record("expected a chord"); return
        }
        #expect(chord.notes.map(\.pitch) == [42])
        #expect(chord.notes.first?.headType == "cross")
    }

    @Test
    func `a second instrument stacks onto the chord already there`() {
        let core = Self.armedCore(Self.drumScore())
        core.pressDrumKey(Self.key(42))

        core.pressDrumKey(Self.key(38))

        guard case let .chord(chord)? = core.score?[Self.slot(element: 1)] else {
            Issue.record("expected a chord"); return
        }
        #expect(chord.notes.map(\.pitch).sorted() == [38, 42])
        #expect(chord.notes.first { $0.pitch == 38 }?.headType == "normal")
    }

    @Test
    func `pressing a lit key takes that instrument away`() {
        let core = Self.armedCore(Self.drumScore())
        core.pressDrumKey(Self.key(42))
        core.pressDrumKey(Self.key(38))

        core.pressDrumKey(Self.key(42))

        guard case let .chord(chord)? = core.score?[Self.slot(element: 1)] else {
            Issue.record("expected a chord"); return
        }
        #expect(chord.notes.map(\.pitch) == [38])
    }

    @Test
    func `taking the last instrument away leaves a rest`() {
        let core = Self.armedCore(Self.drumScore())
        core.pressDrumKey(Self.key(42))

        core.pressDrumKey(Self.key(42))

        guard case let .chord(chord)? = core.score?[Self.slot(element: 1)] else {
            Issue.record("expected a rest"); return
        }
        #expect(chord.notes.isEmpty)
    }

    @Test
    func `a key whose voice the measure lacks grows it first`() {
        let core = Self.armedCore(Self.drumScore())

        core.pressDrumKey(Self.key(36, voice: 1))

        let voices = core.score?.parts[0].staves[0].measures[0].voices
        #expect(voices?.count == 2)
        // The caret is at tick 0 — the bar's first onset — so the new voice's measure rest is written into at its
        // own start and the remainder falls out as aligned rests. No split is needed at a bar's opening column.
        guard case let .chord(chord)? = core.score?[Self.slot(voice: 1, element: 0)] else {
            Issue.record("expected a chord in voice 1"); return
        }
        #expect(chord.notes.map(\.pitch) == [36])
        #expect(chord.duration == .quarter)
    }

    /// The same press one column later, where the fresh voice's measure rest has to be SPLIT before there is a
    /// slot at the caret at all — the whole reason `SplitRest` exists.
    @Test
    func `a fresh voice is split at the caret's column, not written at the bar's start`() {
        let core = Self.armedCore(Self.drumScore())
        core.selectNextElement()

        core.pressDrumKey(Self.key(36, voice: 1))

        let voice1 = core.score?.parts[0].staves[0].measures[0].voices[1]
        // A quarter of silence, the bass drum on beat 2, then the rest of the bar.
        guard case let .chord(opening)? = voice1?.elements.first else { Issue.record("expected a rest"); return }
        #expect(opening.notes.isEmpty)
        #expect(opening.duration == .quarter)
        guard case let .chord(written)? = core.score?[Self.slot(voice: 1, element: 1)] else {
            Issue.record("expected a chord"); return
        }
        #expect(written.notes.map(\.pitch) == [36])
        #expect(written.duration == .quarter)
    }

    /// Without a `<Drum>` row the layout engine falls back to the pitched diatonic formula and draws the note on a
    /// completely wrong line — visible only for instruments the chart never used, which is exactly how it ships
    /// unnoticed. The repair rides in the press's own composite.
    @Test
    func `a pitch the kit never named gets a GM row, and lands on the GM line`() {
        let core = Self.armedCore(Self.drumScore(kit: [38: 2]))

        core.pressDrumKey(Self.key(42))

        let kit = core.score?.parts[0].instrument.drumset
        #expect(kit?[42]?.line == GMDrumset.entries[42]?.line)
        #expect(kit?[42]?.head == "cross")
    }

    @Test
    func `one press is one undo step`() {
        let core = Self.armedCore(Self.drumScore(kit: [38: 2]))
        let before = core.score

        // The heaviest press there is: it repairs the kit, grows a voice, splits its rest and writes the note.
        core.pressDrumKey(Self.key(42, voice: 1))
        #expect(core.score != before)

        core.undo()
        #expect(core.score == before)
    }

    @Test
    func `the caret does not advance, so stacked hits keep landing together`() {
        let core = Self.armedCore(Self.drumScore())
        let column = core.caretColumn

        core.pressDrumKey(Self.key(42))
        core.pressDrumKey(Self.key(38))

        #expect(core.caretColumn == column)
    }

    @Test
    func `the selection lands on the note just written`() {
        let core = Self.armedCore(Self.drumScore())

        core.pressDrumKey(Self.key(42))

        #expect(EditorSessionCore.slot(of: core.selectedItem) == Self.slot(element: 1))
    }

    @Test
    func `a press on a pitched staff does nothing`() {
        let core = Self.armedCore(Self.pitchedScore())
        let before = core.score

        core.pressDrumKey(Self.key(42))

        #expect(core.score == before)
    }

    /// QA (2026-08-30): hi-hats on b1 and b1.5, a quarter bass drum written into the feet voice at b1, then →.
    /// It landed on b2, skipping b1.5 — every beat that has a note or a rest is supposed to be a stop.
    @Test
    func `stepping stops at an onset the caret's own voice runs straight through`() {
        let hiHat = Chord(duration: .eighth, notes: [Note(pitch: 42, tpc: 14, headType: "cross")])
        let voice0 = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(hiHat), .chord(hiHat),
            .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        let staffValue = Staff(
            staffType: GMPercussion.staffTypeName,
            group: GMPercussion.staffGroup,
            measures: [Measure(voices: [voice0])],
        )
        let part = Part(
            id: "1",
            instrument: Instrument(id: "drumset", useDrumset: true, drumLineMap: GMPercussion.drumLineMap),
            staves: [staffValue],
        )
        let core = EditorCoreFixtures.makeCore()
        core.beginSession(score: Score(division: 480, parts: [part]))
        core.select(Self.rest(voice: 0, element: 1))
        core.setDuration(.quarter)

        core.pressDrumKey(Self.key(36, voice: 1))
        core.selectNextElement()

        // b1.5 — where the second hi-hat is — not b2.
        #expect(core.caretColumn?.tick == 240)
        // And the caret is DRAWN on something that actually starts there, not on the bass drum it is inside.
        #expect(EditorSessionCore.slot(of: core.caretItem) == Self.slot(voice: 0, element: 2))
    }

    /// Feet first, then hands, in a bar nothing has been written into yet. The kick goes into its own voice, so
    /// the hands' voice is still one bar-long rest when the caret steps to beat 2 — and writing there has to split
    /// that rest. The caret used to come back on beat 1: the split's HEAD covers the same slot index the rest did,
    /// and re-deriving the caret off a slot lands it wherever that slot starts.
    @Test
    func `writing into a bar-long rest at beat 2 leaves the caret on beat 2`() {
        let core = EditorCoreFixtures.makeCore()
        core.beginSession(score: Self.barRestDrumScore())
        core.select(Self.rest(voice: 0, element: 1))
        core.setDuration(.quarter)

        core.pressDrumKey(Self.key(36, voice: 1))
        core.selectNextElement()
        #expect(core.caretColumn?.tick == 480)

        core.pressDrumKey(Self.key(42, voice: 0))

        #expect(core.caretColumn?.tick == 480)
        #expect(core.litDrumPitches == [42])
    }

    // MARK: - Auditioning

    /// A press previews what it wrote, the way inputting a pitched note does. It shipped silent: the drum path
    /// never marked anything to sound, so the whole pad wrote notes nobody could hear.
    @Test
    func `a press previews the instrument it just wrote`() {
        let core = Self.armedCore(Self.drumScore())

        core.pressDrumKey(Self.key(42))

        let pending = core.takePendingAudition()
        #expect(pending == NoteID(
            staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
        ))
    }

    /// The note named is the one the finger asked for, not whichever happens to be first in the chord — a drum
    /// column normally holds several instruments at once.
    @Test
    func `stacking a second instrument previews that one, not the chord's first`() {
        let core = Self.armedCore(Self.drumScore())

        core.pressDrumKey(Self.key(42))
        _ = core.takePendingAudition()
        core.pressDrumKey(Self.key(38))

        let pending = core.takePendingAudition()
        #expect(pending?.noteIndexInChord == 1)
        #expect(core.litDrumPitches == [42, 38])
    }

    /// Taking an instrument back out has no resulting pitch worth sounding — the same rule the pitched ops follow
    /// for a delete.
    @Test
    func `toggling an instrument off previews nothing`() {
        let core = Self.armedCore(Self.drumScore())

        core.pressDrumKey(Self.key(42))
        core.pressDrumKey(Self.key(38))
        _ = core.takePendingAudition()
        core.pressDrumKey(Self.key(38))

        #expect(core.takePendingAudition() == nil)
        #expect(core.litDrumPitches == [42])
    }
}
