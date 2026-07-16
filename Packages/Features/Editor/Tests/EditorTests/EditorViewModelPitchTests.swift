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
        vm.applyCommand(SetNotePitch(at: noteID, pitch: 127, tpc: 19))
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

    // MARK: - commitPitchDrag

    @Test func `commitPitchDrag two staff steps up lands in-key with no accidental and no auto-advance`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.commitPitchDrag(steps: 2)

        let note = try #require(vm.score?[EditorFixtures.noteID(element: 1)])
        #expect(note.pitch == 64)
        #expect(note.tpc == 18)
        #expect(note.accidental == nil)
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 1)))
    }

    // MARK: - setAccidental

    @Test func `setAccidental sharp respells and clearing it afterwards leaves pitch and tpc alone`() throws {
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
        #expect(note.accidental == nil)
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

        vm.commitPitchDrag(steps: 2)
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
