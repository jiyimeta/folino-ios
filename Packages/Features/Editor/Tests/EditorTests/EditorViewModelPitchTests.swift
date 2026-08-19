import Domain
@testable import Editor
import Foundation
import SheetMusicUI
import Testing

@MainActor
@Suite("EditorViewModel pitch")
struct EditorViewModelPitchTests {
    private func makeViewModel() -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: URL(filePath: "/tmp"),
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            playback: nil,
        )
    }

    // MARK: - shiftPitch

    @Test func `shiftPitch by one semitone up respells via MuseScore arrow-key rules and keeps the selection`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.shiftPitch(bySemitones: 1)

        let note = try #require(vm.score?[EditorFixtures.noteID(element: 1)])
        #expect(note.pitch == 61)
        #expect(note.tpc == PitchSpelling.shiftedTpc(from: 60, priorTpc: 14, to: 61, in: 0))
        #expect(note.accidental == .sharp)
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 1)))
        #expect(vm.generation == 1)
    }

    @Test func `shiftPitch past the MIDI ceiling is a no-op`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        let noteID = EditorFixtures.noteID(element: 1)
        vm.select(.note(noteID))
        vm.apply(.setNotePitch(at: noteID, pitch: 127, tpc: 19, accidental: nil))
        let generationBeforeShift = vm.generation

        vm.shiftPitch(bySemitones: 1)

        #expect(vm.generation == generationBeforeShift)
    }

    // MARK: - shiftOctave

    @Test func `shiftOctave up an octave preserves tpc and accidental`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.shiftOctave(by: 1)

        let note = try #require(vm.score?[EditorFixtures.noteID(element: 1)])
        #expect(note.pitch == 72)
        #expect(note.tpc == 14)
        #expect(note.accidental == nil)
    }

    // MARK: - tie chains

    @Test func `shiftPitch moves every note of the tie chain, not just the selected one`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.tiedC4Chain(length: 3))
        // Selected in the MIDDLE, so the walk has to go both ways.
        vm.select(.note(EditorFixtures.noteID(element: 2)))

        vm.shiftPitch(bySemitones: 1)

        for element in 1 ... 3 {
            let note = try #require(vm.score?[EditorFixtures.noteID(element: element)])
            #expect(note.pitch == 61)
            #expect(note.tpc == PitchSpelling.shiftedTpc(from: 60, priorTpc: 14, to: 61, in: 0))
        }
        // The ♯ belongs to the chain's head; MuseScore prints nothing on the far side of a tie.
        #expect(vm.score?[EditorFixtures.noteID(element: 1)]?.accidental == .sharp)
        #expect(vm.score?[EditorFixtures.noteID(element: 2)]?.accidental == nil)
        #expect(vm.score?[EditorFixtures.noteID(element: 3)]?.accidental == nil)
        // The untied C4 that follows the chain is a different note and stays where it was.
        #expect(vm.score?[EditorFixtures.noteID(element: 4)]?.pitch == 60)
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 2)))
    }

    @Test func `shiftOctave moves every note of the tie chain`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.tiedC4Chain(length: 3))
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.shiftOctave(by: 1)

        for element in 1 ... 3 {
            #expect(vm.score?[EditorFixtures.noteID(element: element)]?.pitch == 72)
        }
        #expect(vm.score?[EditorFixtures.noteID(element: 4)]?.pitch == 60)
    }

    @Test func `moving a chain is one undo step`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.tiedC4Chain(length: 3))
        vm.select(.note(EditorFixtures.noteID(element: 2)))

        vm.shiftPitch(bySemitones: 1)
        vm.undo()

        #expect(!vm.canUndo)
        #expect(vm.score == EditorFixtures.tiedC4Chain(length: 3))
    }

    // MARK: - setAccidental

    @Test func `setAccidental sharp respells, and clearing the glyph can't outlive what the bar needs`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        let noteID = EditorFixtures.noteID(element: 1)
        vm.select(.note(noteID))

        vm.setAccidental(.sharp)

        var note = try #require(vm.score?[noteID])
        #expect(note.pitch == 61)
        #expect(note.tpc == 21)
        #expect(note.accidental == .sharp)

        vm.setAccidental(nil)

        note = try #require(vm.score?[noteID])
        #expect(note.pitch == 61)
        #expect(note.tpc == 21)
        // `nil` clears the glyph, and `MeasureAccidentals` puts it straight back: in C major a C♯ with no ♯ in front
        // of it reads as C natural while still sounding C♯, which is the one thing an editor must never write.
        #expect(note.accidental == .sharp)
    }

    // MARK: - undo granularity

    @Test func `each pitch operation is a single undo step`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.shiftPitch(bySemitones: 1)
        #expect(vm.canUndo)
        vm.undo()
        #expect(!vm.canUndo)
        #expect(vm.score == EditorFixtures.chordAtIndex1())

        vm.shiftOctave(by: 1)
        #expect(vm.canUndo)
        vm.undo()
        #expect(!vm.canUndo)
        #expect(vm.score == EditorFixtures.chordAtIndex1())

        vm.setAccidental(.sharp)
        #expect(vm.canUndo)
        vm.undo()
        #expect(!vm.canUndo)
        #expect(vm.score == EditorFixtures.chordAtIndex1())
    }
}
