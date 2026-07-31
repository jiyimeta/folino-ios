import Domain
@testable import Editor
import Foundation
import SheetMusicUI
import Testing

/// Input of a note longer than the room left in its measure: it continues across the barline as a tied chain
/// instead of being refused outright (which is what made the letter keys look dead near a barline).
@MainActor
@Suite("Cross-barline note input")
struct CrossBarNoteInputTests {
    private func makeViewModel() -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: URL(filePath: "/tmp"),
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            playback: nil,
        )
    }

    private func chord(_ measure: Int, _ element: Int, in viewModel: EditorViewModel) -> Chord? {
        let id = VoiceElementID(
            staff: EditorFixtures.staff0, measureIndex: measure, voiceIndex: 0, elementIndex: element,
        )
        guard case let .chord(chord)? = viewModel.score?[id] else { return nil }
        return chord
    }

    private func elementCount(_ measure: Int, in viewModel: EditorViewModel) -> Int? {
        viewModel.score?.parts[0].staves[0].measures[measure].voices[0].elements.count
    }

    @Test func `a half armed on the last quarter of a bar writes two tied quarters across the barline`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 4))) // beat 4 of bar 1
        vm.setDuration(.half)

        vm.inputPitch(letter: "c")

        let head = try #require(chord(0, 4, in: vm))
        #expect(head.duration == .quarter)
        #expect(head.notes.first?.pitch == 60)
        #expect(head.notes.first?.tieForward == 1)
        #expect(head.notes.first?.tieBack == nil)

        let tail = try #require(chord(1, 0, in: vm))
        #expect(tail.duration == .quarter)
        #expect(tail.notes.first?.pitch == 60)
        #expect(tail.notes.first?.tieBack == 1)
        #expect(tail.notes.first?.tieForward == nil)

        // One composite: one generation bump, one undo step.
        #expect(vm.generation == 1)
    }

    @Test func `the whole chain is beat-aligned and the bars still add up`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 4)))
        vm.setDuration(.whole)

        vm.inputPitch(letter: "c")

        // quarter (bar 1 beat 4) — half + quarter (bar 2 beats 1-3), the beat-aligned spelling of three beats
        // starting on a downbeat. The bar's last beat stays a rest.
        #expect(chord(0, 4, in: vm)?.duration == .quarter)
        #expect(chord(1, 0, in: vm)?.duration == .half)
        #expect(chord(1, 1, in: vm)?.duration == .quarter)
        #expect(chord(1, 2, in: vm)?.notes.isEmpty == true)
        #expect(chord(1, 2, in: vm)?.duration == .quarter)
        #expect(elementCount(1, in: vm) == 3)

        // Every joint tied, and only the joints.
        #expect(chord(0, 4, in: vm)?.notes.first?.tieForward == 1)
        #expect(chord(1, 0, in: vm)?.notes.first?.tieBack == 1)
        #expect(chord(1, 0, in: vm)?.notes.first?.tieForward == 1)
        #expect(chord(1, 1, in: vm)?.notes.first?.tieBack == 1)
        #expect(chord(1, 1, in: vm)?.notes.first?.tieForward == nil)
    }

    @Test func `the chain runs through as many bars as the length needs`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.threeMeasuresOfQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 4)))
        vm.setDuration(.whole)
        vm.setArmedDots(1) // dotted whole = six beats: 1 + 4 + 1

        vm.inputPitch(letter: "c")

        #expect(chord(0, 4, in: vm)?.duration == .quarter)
        #expect(chord(1, 0, in: vm)?.duration == .whole)
        #expect(chord(2, 0, in: vm)?.duration == .quarter)
        #expect(chord(2, 0, in: vm)?.notes.first?.tieForward == nil)
        #expect(chord(2, 1, in: vm)?.notes.isEmpty == true)
    }

    @Test func `the selection lands on the first piece and the caret clears the last one`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 4)))
        vm.setDuration(.whole)

        vm.inputPitch(letter: "c")

        #expect(vm.selectedItem == .note(EditorFixtures.noteID(measure: 0, element: 4)))
        #expect(vm.caretItem == .rest(EditorFixtures.restID(measure: 1, element: 2)))
    }

    @Test func `writing over a note crosses the barline the same way`() {
        var score = EditorFixtures.twoMeasuresOfQuarterRests()
        score[VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 4)] =
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)]))
        let vm = makeViewModel()
        vm.beginSession(score: score)
        vm.select(.note(EditorFixtures.noteID(measure: 0, element: 4)))
        vm.setDuration(.half)

        vm.inputPitch(letter: "c")

        #expect(chord(0, 4, in: vm)?.notes.first?.pitch == 60)
        #expect(chord(0, 4, in: vm)?.notes.first?.tieForward == 1)
        #expect(chord(1, 0, in: vm)?.notes.first?.pitch == 60)
        #expect(chord(1, 0, in: vm)?.notes.first?.tieBack == 1)
    }

    @Test func `notes already in the way are overwritten by the chain`() {
        var score = EditorFixtures.twoMeasuresOfQuarterRests()
        score[VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 0)] =
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 67, tpc: 15)]))
        let vm = makeViewModel()
        vm.beginSession(score: score)
        vm.select(.rest(EditorFixtures.restID(element: 4)))
        vm.setDuration(.half)

        vm.inputPitch(letter: "c")

        #expect(chord(1, 0, in: vm)?.notes.first?.pitch == 60)
        #expect(chord(1, 0, in: vm)?.duration == .quarter)
        #expect(elementCount(1, in: vm) == 4)
    }

    @Test func `undo puts the bars back exactly as they were`() {
        let before = EditorFixtures.twoMeasuresOfQuarterRests()
        let vm = makeViewModel()
        vm.beginSession(score: before)
        vm.select(.rest(EditorFixtures.restID(element: 4)))
        vm.setDuration(.whole)
        vm.inputPitch(letter: "c")

        vm.undo()

        #expect(vm.score == before)
    }

    @Test func `a length the score has no room for is still refused`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests()) // one bar only
        vm.select(.rest(EditorFixtures.restID(element: 4)))
        vm.setDuration(.half)

        vm.inputPitch(letter: "c")

        // Nothing to tie into past the last barline, so the armed length can't be honored at all — better to write
        // nothing than to silently write half of what was asked for.
        #expect(vm.generation == 0)
        #expect(chord(0, 4, in: vm)?.notes.isEmpty == true)
    }

    // MARK: - the tie ＋ key, which writes the armed length one slot on

    @Test func `the tie key carries its note across the barline too`() {
        var score = EditorFixtures.twoMeasuresOfQuarterRests()
        score[VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 3)] =
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let vm = makeViewModel()
        vm.beginSession(score: score)
        vm.select(.note(EditorFixtures.noteID(measure: 0, element: 3)))
        vm.setDuration(.half) // a half from beat 4 has only one beat of bar left

        #expect(vm.canAppendTiedNote)
        vm.appendTiedNote()

        #expect(chord(0, 3, in: vm)?.notes.first?.tieForward == 1)
        #expect(chord(0, 4, in: vm)?.notes.first?.pitch == 60)
        #expect(chord(0, 4, in: vm)?.notes.first?.tieBack == 1)
        #expect(chord(0, 4, in: vm)?.notes.first?.tieForward == 1)
        #expect(chord(1, 0, in: vm)?.notes.first?.tieBack == 1)
        #expect(chord(1, 0, in: vm)?.notes.first?.tieForward == nil)
        #expect(vm.generation == 1)
    }

    @Test func `the tie key stays dim when the chain has nowhere to land`() {
        var score = EditorFixtures.fourQuarterRests() // one bar only
        score[VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 3)] =
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let vm = makeViewModel()
        vm.beginSession(score: score)
        vm.select(.note(EditorFixtures.noteID(measure: 0, element: 3)))
        vm.setDuration(.half)

        #expect(!vm.canAppendTiedNote)
    }

    // MARK: - what must not change

    @Test func `a note that fits its bar is untouched by any of this`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 3)))
        vm.setDuration(.half)

        vm.inputPitch(letter: "c")

        let written = try #require(chord(0, 3, in: vm))
        #expect(written.duration == .half)
        #expect(written.notes.first?.tieForward == nil)
        #expect(elementCount(0, in: vm) == 4) // timeSig + 2 quarters + the half
        #expect(chord(1, 0, in: vm)?.notes.isEmpty == true)
    }
}
