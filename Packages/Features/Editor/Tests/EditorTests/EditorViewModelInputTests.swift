import Domain
@testable import Editor
@testable import EditorCore
import Foundation
import SheetMusicUI
import Testing

@MainActor
@Suite("EditorViewModel input")
struct EditorViewModelInputTests {
    private func makeViewModel() -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: URL(filePath: "/tmp"),
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
    }

    /// Duration of the chord (or rest) at `element` in the fixtures' only voice. `score[VoiceElementID]` hands back a
    /// `VoiceElement`, which carries no duration of its own — the chord inside it does.
    private func duration(atElement element: Int, in viewModel: EditorViewModel) -> NoteDuration? {
        let id = VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element)
        guard case let .chord(chord)? = viewModel.score?[id] else { return nil }
        return chord.duration
    }

    // MARK: - inputPitch

    @Test func `input on a rest writes the note, keeps it selected, and advances only the caret`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.inputPitch(letter: "c")

        let note = try #require(vm.score?[EditorFixtures.noteID(element: 1)])
        #expect(note.pitch == 60)
        #expect(note.tpc == 14)
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 1)))
        #expect(vm.caretItem == .rest(EditorFixtures.restID(element: 2)))
        #expect(vm.generation == 1)
    }

    @Test func `a run of input leaves the caret one slot ahead of the selection`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.inputPitch(letter: "c")
        vm.inputPitch(letter: "d")

        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 2)))
        #expect(vm.caretItem == .rest(EditorFixtures.restID(element: 3)))
    }

    @Test func `sharp after input alters the note just written, and the caret keeps its lead`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))
        vm.inputPitch(letter: "c")

        vm.shiftPitch(bySemitones: 1)

        let note = try #require(vm.score?[EditorFixtures.noteID(element: 1)])
        #expect(note.pitch == 61)
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 1)))
        #expect(vm.caretItem == .rest(EditorFixtures.restID(element: 2)))
    }

    @Test func `a duration key only arms — it never re-times what is already written`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))
        vm.inputPitch(letter: "c")

        vm.setDuration(.eighth)

        #expect(vm.armedDuration == .eighth)
        // Neither the note just written nor the rest under the caret moves; the score is untouched until the next
        // letter key, which is when the armed length is spent.
        #expect(duration(atElement: 1, in: vm) == .quarter)
        #expect(duration(atElement: 2, in: vm) == .quarter)
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 1)))
        #expect(vm.caretItem == .rest(EditorFixtures.restID(element: 2)))

        vm.inputPitch(letter: "d")

        #expect(duration(atElement: 2, in: vm) == .eighth)
    }

    // MARK: - the callout's length keys (the selection's own duration)

    @Test func `the callout reports the selected note's length and re-times it, arming untouched`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        vm.setDuration(.sixteenth) // the pad's arm — must survive, it describes the NEXT note

        #expect(vm.selectedDuration?.base == .quarter)
        #expect(vm.selectedDuration?.dots == 0)

        vm.setSelectionDuration(.half)

        #expect(duration(atElement: 1, in: vm) == .half)
        #expect(vm.selectedDuration?.base == .half)
        #expect(vm.armedDuration == .sixteenth)
    }

    @Test func `the callout stands beside a rest too, and re-times it`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        #expect(!vm.hasSelectionCallout) // nothing selected

        vm.select(.rest(EditorFixtures.restID(element: 1)))

        #expect(vm.hasSelectionCallout)
        #expect(vm.selectedDuration?.base == .quarter)
        #expect(vm.selectedDuration?.dots == 0)

        vm.setSelectionDuration(.half)

        #expect(duration(atElement: 1, in: vm) == .half)
        #expect(vm.selectedDuration?.base == .half)
    }

    @Test func `the callout's dot key dots a selected rest as well`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.toggleSelectionDot()

        let dotted = try #require(duration(atElement: 1, in: vm))
        #expect(dotted.asFraction == NoteDuration.quarter.dotted(1).asFraction)
        #expect(vm.selectedDuration?.dots == 1)
    }

    /// A measure rest reads as a whole rest — that is how the score draws it and so how the card has to label it,
    /// or the tray would open with nothing lit.
    @Test func `a measure rest reports itself as a whole`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))
        vm.setDuration(.whole)
        vm.writeRest() // fills the bar → written as `.measure`

        #expect(duration(atElement: 1, in: vm) == .measure)
        #expect(vm.hasSelectionCallout)
        #expect(vm.selectedDuration?.base == .whole)
        #expect(vm.selectedDuration?.dots == 0)
    }

    @Test func `the callout's dot key dots the selected note and keeps its base length`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.toggleSelectionDot()

        let dotted = try #require(duration(atElement: 1, in: vm))
        #expect(dotted.asFraction == NoteDuration.quarter.dotted(1).asFraction)
        #expect(vm.selectedDuration?.base == .quarter)
        #expect(vm.selectedDuration?.dots == 1)

        vm.toggleSelectionDot()

        #expect(vm.selectedDuration?.dots == 0)
    }

    // MARK: - playback

    @Test func `starting playback drops the selection and the caret`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.isPlaybackActive = true

        #expect(vm.selectedItem == nil)
        #expect(vm.caretItem == nil)
        #expect(!vm.hasEditTarget)
    }

    // MARK: - undo

    /// Undo puts both markers back on the slot whose edit it took away, so the next letter retypes it. Anything else
    /// leaves the caret pointing past a slot the user is looking straight at.
    @Test func `undoing an input puts the caret back on the slot it emptied`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.inputPitch(letter: "c")
        #expect(vm.caretItem == .rest(EditorFixtures.restID(element: 2)))

        vm.undo()

        #expect(vm.caretItem == .rest(EditorFixtures.restID(element: 1)))
        #expect(vm.selectedItem == .rest(EditorFixtures.restID(element: 1)))
    }

    /// The same, one note further in — the case that exposed it. After a SECOND input the caret is on beat 3 and the
    /// slot it names still exists once the undo lands, so re-deriving "the marker the command did not aim at" left
    /// the caret sitting on beat 3 while beat 2 went back to a rest.
    @Test func `undoing the second of two inputs puts the caret back on the second slot`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.inputPitch(letter: "c")
        vm.inputPitch(letter: "d")
        #expect(vm.caretItem == .rest(EditorFixtures.restID(element: 3)))

        vm.undo()

        #expect(vm.caretItem == .rest(EditorFixtures.restID(element: 2)))
        #expect(vm.selectedItem == .rest(EditorFixtures.restID(element: 2)))
        // Beat 1's note is untouched — only the second input came back off.
        #expect(vm.score?[EditorFixtures.noteID(element: 1)] != nil)
    }

    /// Redo is the same rule in the other direction: it lands on what it just put back, ready to be undone again.
    @Test func `redoing an input lands both markers on the note it restored`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.inputPitch(letter: "c")
        vm.inputPitch(letter: "d")
        vm.undo()
        vm.redo()

        #expect(vm.caretItem == .note(EditorFixtures.noteID(element: 2)))
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 2)))
    }

    // MARK: - the rest key

    /// The rhythm this key exists for. Input leaves the selection on the note just written and the caret one slot
    /// on; a rest key addressed at the selection wrote its rest over that note instead of after it.
    @Test func `a rest after a note lands on the next beat, not on the note just written`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1))) // beat 1 of a 4/4 bar

        vm.inputPitch(letter: "c")
        vm.writeRest()

        // Beat 1 still holds the C, beat 2 is now the rest, and the caret has moved on to beat 3.
        let note = try #require(vm.score?[EditorFixtures.noteID(element: 1)])
        #expect(note.pitch == 60)
        guard case let .chord(beat2)? = vm.score?[VoiceElementID(EditorFixtures.restID(element: 2))] else {
            Issue.record("expected a rest on beat 2")
            return
        }
        #expect(beat2.notes.isEmpty)
        #expect(beat2.duration == .quarter)
        #expect(vm.selectedItem == .rest(EditorFixtures.restID(element: 2)))
        #expect(vm.caretItem == .rest(EditorFixtures.restID(element: 3)))
    }

    /// Skipping beats: the slot already holds the rest that was asked for, so nothing is written — but the key was
    /// still a write, and a caret that stayed put would make the bar untypeable.
    @Test func `the rest key advances the caret even when the slot already holds that rest`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))
        vm.setDuration(.quarter) // what beat 1 already is

        vm.writeRest()

        #expect(vm.caretItem == .rest(EditorFixtures.restID(element: 2)))
        #expect(vm.generation == 0) // nothing applied, so no undo step was spent

        vm.writeRest()

        #expect(vm.caretItem == .rest(EditorFixtures.restID(element: 3)))
        #expect(vm.generation == 0)
    }

    /// Deleting survives the move to the caret: a tap places both markers, so the key still turns the note it names
    /// into a rest.
    @Test func `tapping a note and pressing the rest key still replaces that note`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))
        vm.inputPitch(letter: "c")
        vm.inputPitch(letter: "d") // caret is now on beat 3, two slots past the C

        vm.select(.note(EditorFixtures.noteID(element: 1))) // tap the C back

        vm.writeRest()

        guard case let .chord(beat1)? = vm.score?[VoiceElementID(EditorFixtures.restID(element: 1))] else {
            Issue.record("expected a rest on beat 1")
            return
        }
        #expect(beat1.notes.isEmpty)
    }

    @Test func `the rest key re-times a selected rest to the armed length instead of doing nothing`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))
        #expect(vm.canWriteRest) // a rest is a valid target, not just a note

        vm.setDuration(.half)
        vm.writeRest()

        #expect(duration(atElement: 1, in: vm) == .half)
    }

    @Test func `a bar-length rest is written as a measure rest, not a whole rest`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1))) // beat 1 of a 4/4 bar
        vm.setDuration(.whole)

        vm.writeRest()

        // One rest left, and it's `.measure` — the spelling that stays right if the meter ever changes.
        let voice = try #require(vm.score?[EditorFixtures.staff0]?.measures[0].voices[0])
        #expect(voice.elements.count == 2) // time signature + the rest
        #expect(duration(atElement: 1, in: vm) == .measure)
    }

    @Test func `a rest that doesn't fill the bar keeps its own length`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))
        vm.setDuration(.half)

        vm.writeRest()

        #expect(duration(atElement: 1, in: vm) == .half)
    }

    @Test func `the rest key still deletes a selected note`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.c4ThenD4Chords())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.writeRest()

        guard case let .chord(chord)? = vm.score?[VoiceElementID(EditorFixtures.noteID(element: 1))] else {
            Issue.record("expected a chord (rest) at element 1")
            return
        }
        #expect(chord.notes.isEmpty)
    }

    @Test func `the rest key over a note writes the armed length, not the note's own`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1()) // quarter C4 on beat 1, quarter rests after
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.setDuration(.half)
        vm.writeRest()

        // The half the pad was showing — not the quarter the note happened to be.
        #expect(duration(atElement: 1, in: vm) == .half)
        guard case let .chord(rest)? = vm.score?[VoiceElementID(EditorFixtures.restID(element: 1))] else {
            Issue.record("expected a rest at element 1")
            return
        }
        #expect(rest.notes.isEmpty)
        // The half swallowed the quarter rest that followed it; the bar's other two beats stay as they were.
        let voice = try #require(vm.score?[EditorFixtures.staff0]?.measures[0].voices[0])
        #expect(voice.elements.count == 4) // time signature + half + two quarters
        #expect(vm.selectedItem == .rest(EditorFixtures.restID(element: 1)))
    }

    @Test func `the rest key over a note with its own length armed still collapses the bar`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.setDuration(.quarter) // what the note already is — no re-timing asked for
        vm.writeRest()

        // Plain delete, so the emptied bar still reads as one measure rest.
        let voice = try #require(vm.score?[EditorFixtures.staff0]?.measures[0].voices[0])
        #expect(voice.elements.count == 2)
        #expect(duration(atElement: 1, in: vm) == .measure)
    }

    @Test func `a bar-filling armed length over a note writes a measure rest`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1))) // beat 1 of a 4/4 bar

        vm.setDuration(.whole)
        vm.writeRest()

        let voice = try #require(vm.score?[EditorFixtures.staff0]?.measures[0].voices[0])
        #expect(voice.elements.count == 2) // time signature + the rest
        #expect(duration(atElement: 1, in: vm) == .measure)
    }

    // MARK: - tie state

    @Test func `isSelectionTied follows the tie the callout's key toggles`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoConsecutiveC4Chords())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        #expect(vm.canTie)
        #expect(!vm.isSelectionTied)

        vm.toggleTie()
        #expect(vm.isSelectionTied)

        vm.toggleTie()
        #expect(!vm.isSelectionTied)
    }

    // MARK: - arming from the selection

    @Test func `picking a note with nothing armed lights that note's length, and later picks don't override it`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        #expect(vm.armedDuration == nil)

        vm.select(.note(EditorFixtures.noteID(element: 1)))
        #expect(vm.armedDuration == .quarter)
        #expect(vm.armedDots == 0)

        vm.setDuration(.eighth)
        vm.select(.note(EditorFixtures.noteID(element: 1))) // the user's own choice must survive re-selection
        #expect(vm.armedDuration == .eighth)
    }

    // MARK: - dots

    @Test func `the dot key toggles, clamps, and rides on the armed length when input writes`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))
        vm.setDuration(.quarter)

        vm.toggleArmedDot()
        #expect(vm.armedDots == 1)
        vm.toggleArmedDot()
        #expect(vm.armedDots == 0)
        vm.setArmedDots(2)
        #expect(vm.armedDots == 2)
        vm.setArmedDots(9)
        #expect(vm.armedDots == 3)

        vm.setArmedDots(1)
        vm.inputPitch(letter: "c")

        // A dotted quarter is 3/8 of a whole — length and dots are armed separately but land as one duration.
        let written = try #require(duration(atElement: 1, in: vm))
        #expect(written.asFraction == NoteDuration.quarter.dotted(1).asFraction)
    }

    @Test func `a letter key over an existing note re-times it to the armed length as well`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1))) // a quarter; selecting it arms quarter
        vm.setDuration(.half) // …then the user asks for a half

        vm.inputPitch(letter: "d")

        #expect(vm.score?[EditorFixtures.noteID(element: 1)]?.pitch == 62)
        #expect(duration(atElement: 1, in: vm) == .half)
    }

    @Test func `input into a tuplet writes every member, armed length or not`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))
        vm.setDuration(.quarter)
        vm.createTuplet(actualNotes: 3)

        // The members are triplet-scaled, so they never match the armed length — the re-timing that input does on a
        // plain slot would be refused inside a tuplet and used to take the note down with it.
        vm.inputPitch(letter: "c")
        vm.inputPitch(letter: "d")
        vm.inputPitch(letter: "e")

        let voice = try #require(vm.score?[EditorFixtures.staff0]?.measures[0].voices[0])
        #expect(voice.tuplets.first?.actualNotes == 3)
        for (index, expected) in zip(1 ... 3, [60, 62, 64]) {
            guard case let .chord(chord) = voice.elements[index] else {
                Issue.record("expected a chord at element \(index)")
                return
            }
            #expect(chord.notes.first?.pitch == expected)
        }
    }

    // MARK: - pad gating

    @Test func `the pad is inert only while neither marker is set, and note keys need a selected note`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())

        #expect(!vm.hasEditTarget)
        #expect(!vm.isNoteSelected)

        vm.select(.rest(EditorFixtures.restID(element: 1)))
        #expect(vm.hasEditTarget)
        #expect(!vm.isNoteSelected) // a rest is not something ⌫ / ♯ / ♭ can act on

        vm.inputPitch(letter: "c")
        #expect(vm.hasEditTarget)
        #expect(vm.isNoteSelected)
    }

    @Test func `input with an armed duration different from the rest is one composite undo step`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.setDuration(.eighth) // arms; nothing selected yet, so no mutation.
        #expect(vm.generation == 0)
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.inputPitch(letter: "c")

        #expect(vm.generation == 1)
        let note = try #require(vm.score?[EditorFixtures.noteID(element: 1)])
        #expect(note.pitch == 60)
        #expect(note.tpc == 14)
        guard case let .chord(chord)? = vm.score?[VoiceElementID(EditorFixtures.noteID(element: 1))] else {
            Issue.record("expected a chord at element 1")
            return
        }
        #expect(chord.duration == .eighth)
        #expect(vm.score?[EditorFixtures.restID(element: 2)]?.duration == .eighth)
        vm.undo()
        #expect(vm.score == EditorFixtures.fourQuarterRests())
    }

    @Test func `input on a rest already at the armed duration skips the wrapping SetRestDuration`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.setDuration(.quarter)
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.inputPitch(letter: "c")

        #expect(vm.generation == 1)
        vm.undo()
        #expect(vm.score == EditorFixtures.fourQuarterRests())
    }

    @Test func `a letter key on a selected note re-pitches without chord-arming`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.inputPitch(letter: "d")

        let note = try #require(vm.score?[EditorFixtures.noteID(element: 1)])
        #expect(note.pitch == 62)
        #expect(note.tpc == 16)
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 1)))
        #expect(vm.caretItem == .rest(EditorFixtures.restID(element: 2)))
    }

    // MARK: - deleteSelection

    @Test func `deleting the last note in a measure collapses the whole voice to one full-measure rest`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.deleteSelection()

        // [timeSig, rest(quarter) x4] with a chord at index 1 becomes [timeSig, rest(measure)] — a measure-filling
        // rest (`.measure`, NOT `.whole`, so it stays right in any meter), not the four quarter rests the old
        // same-duration delete left behind.
        let voice = try #require(vm.score?[EditorFixtures.staff0]?.measures[0].voices[0])
        #expect(voice.elements.count == 2)
        guard case let .chord(chord) = voice.elements[1] else {
            Issue.record("expected a rest at element 1")
            return
        }
        #expect(chord.notes.isEmpty)
        #expect(chord.duration == .measure)
        #expect(vm.selectedItem == .rest(EditorFixtures.restID(element: 1)))
        // Still one undo step: the collapse replaces the delete rather than following it.
        vm.undo()
        #expect(vm.score == EditorFixtures.chordAtIndex1())
    }

    @Test func `deleting one of two notes leaves the measure's rhythm alone`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.c4ThenD4Chords())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.deleteSelection()

        let element = try #require(vm.score?[VoiceElementID(EditorFixtures.noteID(element: 1))])
        guard case let .chord(chord) = element else {
            Issue.record("expected a chord (rest)")
            return
        }
        #expect(chord.notes.isEmpty)
        #expect(chord.duration == .quarter)
        #expect(vm.selectedItem == .rest(EditorFixtures.restID(element: 1)))
    }

    // MARK: - setDuration

    @Test func `setDuration leaves the selected note and the score alone`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.setDuration(.eighth)

        #expect(vm.armedDuration == .eighth)
        #expect(vm.generation == 0)
        #expect(vm.score == EditorFixtures.chordAtIndex1())
    }

    @Test func `setDuration on a selected rest arms without lengthening it`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.setDuration(.half)

        #expect(vm.armedDuration == .half)
        #expect(vm.score == EditorFixtures.fourQuarterRests())
        // The armed length reaches the score only when something is written into that slot.
        vm.inputPitch(letter: "c")
        #expect(duration(atElement: 1, in: vm) == .half)
    }

    // MARK: - referencePitch

    @Test func `referencePitch walks back to the previous chord's first note`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        let location = VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 3)

        #expect(vm.core.referencePitch(before: location) == 60)
    }

    @Test func `referencePitch is nil when only non-timed elements precede`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        let location = VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)

        #expect(vm.core.referencePitch(before: location) == nil)
    }
}
