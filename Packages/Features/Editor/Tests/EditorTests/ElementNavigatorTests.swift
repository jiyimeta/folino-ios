import Domain
@testable import Editor
import Foundation
import Testing

@Suite("ElementNavigator")
struct ElementNavigatorTests {
    @Test func `finds the next rest in the same measure`() {
        let score = EditorFixtures.fourQuarterRests()
        let after = VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)

        let next = ElementNavigator.nextTimedElement(after: after, in: score)

        #expect(next == VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 2))
    }

    @Test func `nil after the last element of a single-measure staff`() {
        let score = EditorFixtures.fourQuarterRests()
        let after = VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 4)

        let next = ElementNavigator.nextTimedElement(after: after, in: score)

        #expect(next == nil)
    }

    @Test func `continues into the next measure's same voice`() {
        var score = EditorFixtures.fourQuarterRests()
        score.parts[0].staves[0].measures.append(
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
        )
        let after = VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 4)

        let next = ElementNavigator.nextTimedElement(after: after, in: score)

        #expect(next == VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 0))
    }

    @Test func `skips non-timed elements at the start of the next measure`() {
        var score = EditorFixtures.fourQuarterRests()
        let secondMeasure = Measure(voices: [
            Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .rest(duration: .quarter),
            ]),
        ])
        score.parts[0].staves[0].measures.append(secondMeasure)
        let after = VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 4)

        let next = ElementNavigator.nextTimedElement(after: after, in: score)

        #expect(next == VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 1))
    }
}
