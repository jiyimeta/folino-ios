import Domain
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderEditingDisplayTests {
    private func score() -> Score {
        let staff = Staff(measures: [Measure(voices: [Voice(elements: [.rest(duration: .whole)])])])
        let part = Part(id: "P", instrument: Instrument(id: "piano"), staves: [staff])
        return Score(division: 480, parts: [part])
    }

    @Test func `nil host or a host that is not editing yields nil and version 0`() {
        #expect(ReaderEditingDisplay.score(host: nil, clefOverrides: [:], hiddenStaves: []) == nil)
        #expect(ReaderEditingDisplay.version(host: nil) == 0)
        let host = ReaderEditingHost()
        host.editedScore = score()
        host.editGeneration = 7
        #expect(ReaderEditingDisplay.score(host: host, clefOverrides: [:], hiddenStaves: []) == nil)
        #expect(ReaderEditingDisplay.version(host: host) == 0)
    }

    @Test func `an editing host yields the display-transformed edited score and its generation`() {
        let host = ReaderEditingHost()
        host.isEditing = true
        host.editedScore = score()
        host.editGeneration = 3
        let expected = ReaderDisplayTransforms.display(
            score(), clefOverrides: [:], transposeSemitones: 0, hiddenStaves: [],
        )
        #expect(ReaderEditingDisplay.score(host: host, clefOverrides: [:], hiddenStaves: []) == expected)
        #expect(ReaderEditingDisplay.version(host: host) == 3)
    }
}
