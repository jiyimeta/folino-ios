import Domain
import EditorCore
import Foundation
import Testing

@Suite("SelectionRederivation")
struct SelectionRederivationTests {
    @Test func `chord with a note re-derives to a note selection`() {
        let score = EditorCoreFixtures.chordAtIndex1()
        let location = VoiceElementID(
            staff: EditorCoreFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )

        let item = SelectionRederivation.item(at: location, in: score, preferringNoteIndex: nil)

        #expect(item == .note(EditorCoreFixtures.noteID(element: 1)))
    }

    @Test func `empty chord (a rest) re-derives to a rest selection`() {
        let score = EditorCoreFixtures.chordAtIndex1()
        let location = VoiceElementID(
            staff: EditorCoreFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 2,
        )

        let item = SelectionRederivation.item(at: location, in: score, preferringNoteIndex: nil)

        #expect(item == .rest(EditorCoreFixtures.restID(element: 2)))
    }

    @Test func `non-timed element re-derives to nil`() {
        let score = EditorCoreFixtures.chordAtIndex1()
        let location = VoiceElementID(
            staff: EditorCoreFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )

        let item = SelectionRederivation.item(at: location, in: score, preferringNoteIndex: nil)

        #expect(item == nil)
    }

    @Test func `out of range element index re-derives to nil`() {
        let score = EditorCoreFixtures.chordAtIndex1()
        let location = VoiceElementID(
            staff: EditorCoreFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 99,
        )

        let item = SelectionRederivation.item(at: location, in: score, preferringNoteIndex: nil)

        #expect(item == nil)
    }

    @Test func `preferred note index clamps to the last note in a smaller chord`() {
        let score = EditorCoreFixtures.chordAtIndex1()
        let location = VoiceElementID(
            staff: EditorCoreFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )

        let item = SelectionRederivation.item(at: location, in: score, preferringNoteIndex: 5)

        #expect(item == .note(EditorCoreFixtures.noteID(element: 1, noteIndex: 0)))
    }
}
