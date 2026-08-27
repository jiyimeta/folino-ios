import Domain
@testable import Editor
import Foundation
import SheetMusicUI
import Testing

/// Pins the `EditIntent` each op constructs — the test style the intent seam buys: an op's contract with the engine
/// is now a value, so "what did this key ask for" is a plain equality check. Behavior is covered by the pre-existing
/// op suites; these lock the shape handed to `ScoreEditSession`, the two host-side compensations (caret past a
/// cross-barline chain's tail; selection pinned to the source after a tie-append), and the chord-upper-notehead
/// ruling.
@MainActor
@Suite("Editor intent construction")
struct EditorIntentConstructionTests {
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

    // MARK: - Note input

    @Test func `letter input on a rest with no re-time records a bare inputNote`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1))) // arms .quarter — the slot's own length
        vm.inputPitch(letter: "c")
        #expect(vm.appliedIntents == [
            .inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil),
        ])
    }

    @Test func `letter input on a rest with a different armed length carries it as the intent's duration`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))
        vm.setDuration(.eighth)
        vm.inputPitch(letter: "d")
        #expect(vm.appliedIntents == [
            .inputNote(at: EditorFixtures.restID(element: 1), pitch: 62, tpc: 16, duration: .eighth),
        ])
    }

    @Test func `a cross-barline write lands the selection on the chain head and the caret past its tail`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 4))) // measure 0's LAST quarter slot
        vm.setDuration(.half)
        vm.inputPitch(letter: "c")
        // One quarter of room left in the bar: the half is spelled quarter + quarter tied across the barline —
        // by ssm, from this one scalar intent.
        #expect(vm.appliedIntents == [
            .inputNote(at: EditorFixtures.restID(element: 4), pitch: 60, tpc: 14, duration: .half),
        ])
        let head = try #require(vm.score?[EditorFixtures.noteID(element: 4)])
        #expect(head.tieForward == 1)
        let tail = try #require(vm.score?[EditorFixtures.noteID(measure: 1, element: 0)])
        #expect(tail.tieBack == 1)
        // Compensation 1: selection on the chain's head, caret past its TAIL — the session reports only the head.
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 4)))
        #expect(vm.caretItem == .rest(EditorFixtures.restID(measure: 1, element: 1)))
    }

    @Test func `letter input over a note records writeNote and still advances the caret`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1))) // arms .quarter — the chord's own length
        vm.inputPitch(letter: "d")
        #expect(vm.appliedIntents == [
            .writeNote(
                at: VoiceElementID(EditorFixtures.noteID(element: 1)), pitch: 62, tpc: 16, duration: nil,
            ),
        ])
        #expect(vm.score?[EditorFixtures.noteID(element: 1)]?.pitch == 62)
        #expect(vm.caretItem == .rest(EditorFixtures.restID(element: 2)))
    }

    /// The one real behavioral fork the spec flags: `.writeNote` re-pitches notehead 0, but a
    /// caret naming a chord's UPPER notehead — the ＋音-then-fix flow — means THAT notehead, so the host builds a
    /// `.setNotePitch` for it instead.
    @Test func `letter input with the caret on a chord's upper notehead re-pitches that notehead, not the root`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoNoteChordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1, noteIndex: 1))) // the E4 above the C4 root
        vm.inputPitch(letter: "d")
        #expect(vm.appliedIntents == [
            .setNotePitch(
                at: EditorFixtures.noteID(element: 1, noteIndex: 1), pitch: 62, tpc: 16, accidental: nil,
            ),
        ])
        #expect(vm.score?[EditorFixtures.noteID(element: 1, noteIndex: 0)]?.pitch == 60) // the root stays
        #expect(vm.score?[EditorFixtures.noteID(element: 1, noteIndex: 1)]?.pitch == 62) // the E became D
    }

    // MARK: - Delete and the rest key

    @Test func `deleting the bar's only note records a plain delete and lands on the collapsed measure rest`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        vm.deleteSelection()
        #expect(vm.appliedIntents == [.delete(at: VoiceElementID(EditorFixtures.noteID(element: 1)))])
        // ssm collapsed the emptied bar to ONE measure rest and reported it as the affected location.
        #expect(vm.selectedItem == .rest(EditorFixtures.restID(element: 1)))
    }

    @Test func `deleting one note of a chord records removeNoteFromChord`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoNoteChordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1, noteIndex: 1)))
        vm.deleteSelection()
        #expect(vm.appliedIntents == [
            .removeNoteFromChord(at: EditorFixtures.noteID(element: 1, noteIndex: 1)),
        ])
    }

    @Test func `the rest key over a note with a different armed length records writeRest`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        vm.setDuration(.half)
        vm.writeRest()
        #expect(vm.appliedIntents == [
            .writeRest(at: VoiceElementID(EditorFixtures.noteID(element: 1)), duration: .half),
        ])
    }

    @Test func `the rest key with the note's own length armed falls back to delete`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1))) // arms .quarter, the note's own length
        vm.writeRest()
        #expect(vm.appliedIntents == [.delete(at: VoiceElementID(EditorFixtures.noteID(element: 1)))])
    }

    // MARK: - The callout's length keys

    @Test func `the callout's length key on a note records setChordDuration`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        vm.setSelectionDuration(.half)
        #expect(vm.appliedIntents == [
            .setChordDuration(at: VoiceElementID(EditorFixtures.noteID(element: 1)), duration: .half),
        ])
    }

    @Test func `the callout's length key on a rest records the raw length and ssm promotes the bar-filler`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))
        vm.setSelectionDuration(.whole)
        // The intent carries what the key said; the `.measure` spelling is ssm's promotion, applied engine-side.
        #expect(vm.appliedIntents == [
            .setRestDuration(at: VoiceElementID(EditorFixtures.restID(element: 1)), duration: .whole),
        ])
        guard case let .chord(rest)? = vm.score?[VoiceElementID(EditorFixtures.restID(element: 1))] else {
            Issue.record("expected a rest at element 1")
            return
        }
        #expect(rest.duration == .measure)
    }

    // MARK: - Ties

    @Test func `the tie toggle records setTie in both directions`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoConsecutiveC4Chords())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        vm.toggleTie()
        vm.toggleTie()
        #expect(vm.appliedIntents == [
            .setTie(
                from: EditorFixtures.noteID(element: 1), to: EditorFixtures.noteID(element: 2),
                sourceTieForward: 1, targetTieBack: 1,
            ),
            .setTie(
                from: EditorFixtures.noteID(element: 1), to: EditorFixtures.noteID(element: 2),
                sourceTieForward: nil, targetTieBack: nil,
            ),
        ])
    }

    @Test func `appendTiedNote records the inputNote + setTie composite and keeps the source selected`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1))) // arms .quarter — the next slot's own length too
        vm.appendTiedNote()
        #expect(vm.appliedIntents == [
            .composite([
                .inputNote(at: EditorFixtures.restID(element: 2), pitch: 60, tpc: 14, duration: nil),
                .setTie(
                    from: EditorFixtures.noteID(element: 1), to: EditorFixtures.noteID(element: 2),
                    sourceTieForward: 1, targetTieBack: 1,
                ),
            ]),
        ])
        // Compensation 2: ssm's composite reports its first member's location (the appended note); the selection
        // belongs on the SOURCE, re-landed explicitly.
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 1)))
    }

    @Test func `appendTiedNote across the barline ties onto the chain's head at the written slot`() throws {
        var score = EditorFixtures.twoMeasuresOfQuarterRests()
        score[VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 3)] =
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let vm = makeViewModel()
        vm.beginSession(score: score)
        vm.select(.note(EditorFixtures.noteID(element: 3)))
        vm.setDuration(.half)
        vm.appendTiedNote()
        // One quarter of room after the source: the appended half is spelled quarter + quarter across the barline
        // by ssm, and the tie from the source lands on the chain's head — the very slot being written.
        #expect(vm.appliedIntents == [
            .composite([
                .inputNote(at: EditorFixtures.restID(element: 4), pitch: 60, tpc: 14, duration: .half),
                .setTie(
                    from: EditorFixtures.noteID(element: 3), to: EditorFixtures.noteID(element: 4),
                    sourceTieForward: 1, targetTieBack: 1,
                ),
            ]),
        ])
        let head = try #require(vm.score?[EditorFixtures.noteID(element: 4)])
        #expect(head.tieBack == 1) // tied from the source note
        #expect(head.tieForward == 1) // and onward into its own chain
        let chainTail = try #require(vm.score?[EditorFixtures.noteID(measure: 1, element: 0)])
        #expect(chainTail.tieBack == 1)
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 3)))
    }

    // MARK: - Pitch and accidentals

    @Test func `the chevrons record one setNotePitch and ssm walks the tie chain`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.tiedC4Chain(length: 3))
        vm.select(.note(EditorFixtures.noteID(element: 2))) // the chain's MIDDLE member
        vm.shiftPitch(bySemitones: 1)
        #expect(vm.appliedIntents == [
            .setNotePitch(
                at: EditorFixtures.noteID(element: 2),
                pitch: 61,
                tpc: PitchSpelling.shiftedTpc(from: 60, priorTpc: 14, to: 61, in: 0),
                accidental: .sharp,
            ),
        ])
        // The chain moved whole — that walk is ssm's now, from this one scalar intent.
        #expect(vm.score?[EditorFixtures.noteID(element: 1)]?.pitch == 61)
        #expect(vm.score?[EditorFixtures.noteID(element: 3)]?.pitch == 61)
        #expect(vm.score?[EditorFixtures.noteID(element: 4)]?.pitch == 60) // the untied neighbour stays
    }

    @Test func `the accidental key records setAccidental`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        vm.setAccidental(.sharp)
        #expect(vm.appliedIntents == [
            .setAccidental(at: EditorFixtures.noteID(element: 1), accidental: .sharp),
        ])
    }

    @Test func `the armed chord key records addNoteToChord`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        vm.toggleAddToChord()
        vm.inputPitch(letter: "e")
        #expect(vm.appliedIntents == [
            .addNoteToChord(
                at: VoiceElementID(EditorFixtures.noteID(element: 1)), pitch: 64, tpc: 18, accidental: nil,
            ),
        ])
    }

    // MARK: - Tuplets

    @Test func `the tuplet key records createTuplet and removeTuplet at the caret's slot`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))
        vm.createTuplet(actualNotes: 3)
        vm.removeTuplet()
        let slot = VoiceElementID(EditorFixtures.restID(element: 1))
        #expect(vm.appliedIntents == [
            .createTuplet(at: slot, actualNotes: 3, normalNotes: 2),
            .removeTuplet(at: slot),
        ])
    }
}
