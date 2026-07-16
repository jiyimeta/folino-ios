import Domain
@testable import Editor
import Foundation
import SheetMusicUI
import Testing

@MainActor
@Suite("EditorViewModel chord/tie/tuplet")
struct EditorViewModelChordTests {
    private func makeViewModel() -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: URL(filePath: "/tmp"),
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            playback: nil,
        )
    }

    // MARK: - toggleAddToChord + inputPitch

    @Test func `arming add-to-chord then a letter key adds to the chord without auto-advancing`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.toggleAddToChord()
        #expect(vm.isAddToChordArmed)

        vm.inputPitch(letter: "e")

        guard case let .chord(chord)? = vm.score?[VoiceElementID(EditorFixtures.noteID(element: 1))] else {
            Issue.record("expected a chord at element 1")
            return
        }
        #expect(chord.notes.map(\.pitch) == [60, 64])
        #expect(!vm.isAddToChordArmed)
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 1, noteIndex: 1)))
    }

    @Test func `armed add of a duplicate pitch is swallowed and clears the arm`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        vm.toggleAddToChord()

        vm.inputPitch(letter: "c")

        #expect(vm.generation == 0)
        #expect(!vm.isAddToChordArmed)
        guard case let .chord(chord)? = vm.score?[VoiceElementID(EditorFixtures.noteID(element: 1))] else {
            Issue.record("expected a chord at element 1")
            return
        }
        #expect(chord.notes.map(\.pitch) == [60])
    }

    // MARK: - removeSelectedNoteFromChord

    @Test func `removing a note from a two-note chord leaves one note, and the last note leaves a rest`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoNoteChordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1, noteIndex: 1)))

        vm.removeSelectedNoteFromChord()

        var element = try #require(vm.score?[VoiceElementID(EditorFixtures.noteID(element: 1))])
        guard case let .chord(chord) = element else {
            Issue.record("expected a chord at element 1")
            return
        }
        #expect(chord.notes.map(\.pitch) == [60])

        vm.removeSelectedNoteFromChord()

        element = try #require(vm.score?[VoiceElementID(EditorFixtures.noteID(element: 1))])
        #expect(element.isRest)
    }

    // MARK: - addIntervalNote

    @Test func `addIntervalNote adds a diatonic third, and separately an octave, above the selected note`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.addIntervalNote(.third)

        guard case let .chord(afterThird)? = vm.score?[VoiceElementID(EditorFixtures.noteID(element: 1))] else {
            Issue.record("expected a chord at element 1")
            return
        }
        #expect(afterThird.notes.map(\.pitch) == [60, 64])

        vm.select(.note(EditorFixtures.noteID(element: 1))) // re-select the root before the next interval add
        vm.addIntervalNote(.octave)

        guard case let .chord(afterOctave)? = vm.score?[VoiceElementID(EditorFixtures.noteID(element: 1))] else {
            Issue.record("expected a chord at element 1")
            return
        }
        #expect(afterOctave.notes.map(\.pitch).contains(72))
    }

    // MARK: - canTie / toggleTie

    @Test func `toggleTie adds and removes a tie between two same-pitch notes`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoConsecutiveC4Chords())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        #expect(vm.canTie)

        vm.toggleTie()

        var source = try #require(vm.score?[EditorFixtures.noteID(element: 1)])
        var target = try #require(vm.score?[EditorFixtures.noteID(element: 2)])
        #expect(source.tieForward == 1)
        #expect(target.tieBack == 1)

        vm.toggleTie()

        source = try #require(vm.score?[EditorFixtures.noteID(element: 1)])
        target = try #require(vm.score?[EditorFixtures.noteID(element: 2)])
        #expect(source.tieForward == nil)
        #expect(target.tieBack == nil)
    }

    @Test func `canTie is false and toggleTie is a no-op when the next chord is a different pitch`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.c4ThenD4Chords())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        #expect(!vm.canTie)

        vm.toggleTie()

        #expect(vm.generation == 0)
    }

    // MARK: - createTuplet / removeTuplet / isSelectionInTuplet

    @Test func `createTuplet builds a triplet and removeTuplet collapses it back; undo redo round-trip the data`(
    ) throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.createTuplet(actualNotes: 3)

        let voice = try #require(vm.score?[EditorFixtures.staff0]?.measures[0].voices[0])
        #expect(voice.tuplets.first == Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3))
        guard case let .chord(firstMember)? =
            vm.score?[VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)]
        else {
            Issue.record("expected the first tuplet member to be a chord")
            return
        }
        #expect(firstMember.notes.map(\.pitch) == [60])
        #expect(vm.isSelectionInTuplet)

        vm.removeTuplet()

        #expect(!vm.isSelectionInTuplet)
        let collapsedVoice = try #require(vm.score?[EditorFixtures.staff0]?.measures[0].voices[0])
        #expect(collapsedVoice.tuplets.isEmpty)
        guard case let .chord(collapsed)? =
            vm.score?[VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)]
        else {
            Issue.record("expected a collapsed chord at element 1")
            return
        }
        #expect(collapsed.notes.map(\.pitch) == [60])
        #expect(collapsed.duration.asFraction == NoteDuration.quarter.asFraction)

        vm.undo() // undoes removeTuplet -> tuplet data restored
        let restoredVoice = try #require(vm.score?[EditorFixtures.staff0]?.measures[0].voices[0])
        #expect(restoredVoice.tuplets.first == Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3))

        vm.undo() // undoes createTuplet -> back to the original single quarter chord
        #expect(vm.score == EditorFixtures.chordAtIndex1())

        vm.redo() // redoes createTuplet
        let redoneVoice = try #require(vm.score?[EditorFixtures.staff0]?.measures[0].voices[0])
        #expect(redoneVoice.tuplets.first == Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3))

        vm.redo() // redoes removeTuplet
        let finalVoice = try #require(vm.score?[EditorFixtures.staff0]?.measures[0].voices[0])
        #expect(finalVoice.tuplets.isEmpty)
    }
}
