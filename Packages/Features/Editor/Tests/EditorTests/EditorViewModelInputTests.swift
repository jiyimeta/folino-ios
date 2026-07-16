import Domain
@testable import Editor
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
            playback: nil,
        )
    }

    // MARK: - inputPitch

    @Test func `input on a rest with no armed duration inputs the note and auto-advances`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.inputPitch(letter: "c")

        let note = try #require(vm.score?[EditorFixtures.noteID(element: 1)])
        #expect(note.pitch == 60)
        #expect(note.tpc == 14)
        #expect(vm.selectedItem == .rest(EditorFixtures.restID(element: 2)))
        #expect(vm.generation == 1)
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
        #expect(vm.selectedItem == .rest(EditorFixtures.restID(element: 2)))
    }

    // MARK: - deleteSelection

    @Test func `deleting a single-note chord collapses it to a same-duration rest`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.deleteSelection()

        let veID = VoiceElementID(EditorFixtures.noteID(element: 1))
        let element = try #require(vm.score?[veID])
        #expect(element.isRest)
        guard case let .chord(chord) = element else {
            Issue.record("expected a chord (rest)")
            return
        }
        #expect(chord.duration == .quarter)
        #expect(vm.selectedItem == .rest(EditorFixtures.restID(element: 1)))
    }

    // MARK: - setDuration

    @Test func `setDuration on a selected note changes the chord duration and arms`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.setDuration(.eighth)

        guard case let .chord(chord)? = vm.score?[VoiceElementID(EditorFixtures.noteID(element: 1))] else {
            Issue.record("expected a chord at element 1")
            return
        }
        #expect(chord.duration == .eighth)
        #expect(vm.score?[EditorFixtures.restID(element: 2)]?.duration == .eighth)
        #expect(vm.armedDuration == .eighth)
    }

    @Test func `setDuration on a selected rest lengthens it and preserves the measure`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.setDuration(.half)

        #expect(vm.score?[EditorFixtures.restID(element: 1)]?.duration == .half)
        vm.undo()
        #expect(vm.score == EditorFixtures.fourQuarterRests())
    }

    // MARK: - referencePitch

    @Test func `referencePitch walks back to the previous chord's first note`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        let location = VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 3)

        #expect(vm.referencePitch(before: location) == 60)
    }

    @Test func `referencePitch is nil when only non-timed elements precede`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        let location = VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)

        #expect(vm.referencePitch(before: location) == nil)
    }
}
