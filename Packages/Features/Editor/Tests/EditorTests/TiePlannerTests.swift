import Domain
@testable import Editor
import Foundation
import Testing

@Suite("TiePlanner")
struct TiePlannerTests {
    @Test func `finds a same-pitch tie target in the next chord`() {
        let score = EditorFixtures.twoConsecutiveC4Chords()

        let target = TiePlanner.tieTarget(for: EditorFixtures.noteID(element: 1), in: score)

        #expect(target == EditorFixtures.noteID(element: 2))
    }

    @Test func `a different pitch in the next chord is not a tie target`() {
        let score = EditorFixtures.c4ThenD4Chords()

        let target = TiePlanner.tieTarget(for: EditorFixtures.noteID(element: 1), in: score)

        #expect(target == nil)
    }

    @Test func `finds a same-pitch tie target across the barline`() {
        let score = EditorFixtures.c4AcrossBarline()

        let target = TiePlanner.tieTarget(for: EditorFixtures.noteID(element: 4), in: score)

        let expected = NoteID(
            staff: EditorFixtures.staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
        )
        #expect(target == expected)
    }
}
