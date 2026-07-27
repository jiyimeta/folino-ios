import Domain
import Foundation
@testable import Reader
import Testing

@MainActor
@Suite("ReaderViewModel edit-mode score adoption")
struct ReaderViewModelEditingTests {
    private func makeVM(controller: FakePlaybackController) -> ReaderViewModel {
        ReaderViewModel(
            scoreItem: PreviewFakeRepository.sampleItem,
            repository: FakeScoreLibraryRepository(),
            gateway: FakeScoreFileGateway(),
            scoresDirectory: FileManager.default.temporaryDirectory,
            playbackController: controller,
        )
    }

    private func makeEditedScore() -> Score {
        let chord = Chord(duration: .quarter, notes: [Note(pitch: 67, tpc: 15)])
        let voice = Voice(elements: [.chord(chord)])
        let staff = Staff(measures: [Measure(voices: [voice])])
        let part = Part(id: "EDITED", instrument: Instrument(id: "piano"), staves: [staff])
        return Score(division: 480, parts: [part])
    }

    /// Mirrors the `advance(to:)` reload sequence without swapping the item: adopting the edited score should replace
    /// the loaded score, recompute the display projection (identity at the default transpose/clef/hidden-staves
    /// settings), and tear down + re-prepare the audio engine so the sequencer picks up the new note content.
    @Test
    func `adoptEditedScore replaces the loaded score, recomputes visibleScore, and reloads the engine`() async {
        let controller = FakePlaybackController()
        let vm = makeVM(controller: controller)
        await vm.load()
        await vm.playbackSession.prepareForPlayback()
        #expect(controller.loadCount == 1)
        #expect(controller.releaseEngineCount == 0)

        let edited = makeEditedScore()
        await vm.adoptEditedScore(edited)

        #expect(vm.loadState.score == edited)
        #expect(vm.visibleScore == edited)
        #expect(controller.releaseEngineCount == 1)
        #expect(controller.loadCount == 2)
    }
}
