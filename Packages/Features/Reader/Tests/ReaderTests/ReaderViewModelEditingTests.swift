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

    /// The whole point of the stale check: pressing play mid-session has to hear the notes just written. Adoption
    /// used to run only at `finishEditing()`, so everything played during a session was the pre-session score.
    @Test
    func `pressing play mid-session reloads the engine from the edited score`() async {
        let controller = FakePlaybackController()
        let vm = makeVM(controller: controller)
        await vm.load()
        await vm.playbackSession.prepareForPlayback()
        #expect(controller.loadCount == 1)

        let edited = makeEditedScore()
        vm.editedScoreProvider = { edited }

        await vm.playbackSession.togglePlayback()

        #expect(vm.loadState.score == edited)
        #expect(controller.releaseEngineCount == 1)
        #expect(controller.loadCount == 2)
    }

    /// The other half, and the reason the check compares scores instead of trusting a flag: `startEditing` seeds the
    /// host with the score already loaded, so an edit session that has changed nothing must cost nothing. A reload
    /// here would stall every "tap 音符入力, then play".
    @Test
    func `pressing play with nothing edited leaves the engine alone`() async {
        let controller = FakePlaybackController()
        let vm = makeVM(controller: controller)
        await vm.load()
        await vm.playbackSession.prepareForPlayback()
        let loaded = vm.loadState.score
        vm.editedScoreProvider = { loaded }

        await vm.playbackSession.togglePlayback()

        #expect(controller.releaseEngineCount == 0)
        #expect(controller.loadCount == 1)
    }

    /// Outside an edit session the provider answers nil, and the transport is untouched.
    @Test
    func `pressing play outside an edit session leaves the engine alone`() async {
        let controller = FakePlaybackController()
        let vm = makeVM(controller: controller)
        await vm.load()
        await vm.playbackSession.prepareForPlayback()

        await vm.playbackSession.togglePlayback()

        #expect(controller.releaseEngineCount == 0)
        #expect(controller.loadCount == 1)
    }
}
