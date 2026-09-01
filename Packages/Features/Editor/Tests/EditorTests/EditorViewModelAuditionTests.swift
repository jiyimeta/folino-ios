import Domain
@testable import Editor
import Foundation
import SheetMusicUI
import Testing

/// Audition: a fire-and-forget pitch preview on note input and pitch change (spec §5.6). `audition(_:)`
/// stores its spawned work in `vm.auditionTask`, so tests await that instead of racing the fire-and-forget call.
@MainActor
@Suite("EditorViewModel audition")
struct EditorViewModelAuditionTests {
    private func makeViewModel(playback: FakePlaybackController?) -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: URL(filePath: "/tmp"),
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
            playback: playback,
        )
    }

    @Test func `input on a rest fires one audition call for the freshly-input note`() async {
        let fake = FakePlaybackController()
        let vm = makeViewModel(playback: fake)
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.inputPitch(letter: "c")
        await vm.auditionTask?.value

        #expect(fake.recordedScorePreviewCalls.count == 1)
        #expect(fake.recordedScorePreviewCalls.first?.noteID == EditorFixtures.noteID(element: 1))
        #expect(fake.recordedScorePreviewCalls.first?.duration == 0.5)
    }

    @Test func `shiftPitch fires one audition call for the same NoteID`() async {
        let fake = FakePlaybackController()
        let vm = makeViewModel(playback: fake)
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.shiftPitch(bySemitones: 1)
        await vm.auditionTask?.value

        #expect(fake.recordedScorePreviewCalls.count == 1)
        #expect(fake.recordedScorePreviewCalls.first?.noteID == EditorFixtures.noteID(element: 1))
        #expect(fake.recordedScorePreviewCalls.first?.duration == 0.5)
    }

    /// Stepping is a pick, exactly as a tap is: the caret says where you are, the note says what is there. Walking a
    /// passage with the arrow keys in silence made it a guessing game.
    @Test func `stepping the selection sounds the note it lands on`() async {
        let fake = FakePlaybackController()
        let vm = makeViewModel(playback: fake)
        vm.beginSession(score: EditorFixtures.c4ThenD4Chords())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.selectNextElement()
        await vm.auditionTask?.value

        #expect(fake.recordedScorePreviewCalls.map(\.noteID) == [EditorFixtures.noteID(element: 2)])
    }

    /// Same rule a tap keeps: never lay a one-shot preview over a running transport.
    @Test func `stepping is silent while the transport runs`() async {
        let fake = FakePlaybackController()
        let vm = makeViewModel(playback: fake)
        vm.beginSession(score: EditorFixtures.c4ThenD4Chords())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        vm.isPlaybackActive = true

        vm.selectNextElement()
        await vm.auditionTask?.value

        #expect(fake.recordedScorePreviewCalls.isEmpty)
    }

    /// A step that lands on a rest has nothing to sound.
    @Test func `stepping onto a rest sounds nothing`() async {
        let fake = FakePlaybackController()
        let vm = makeViewModel(playback: fake)
        vm.beginSession(score: EditorFixtures.chordAtIndex1()) // quarter C4, then quarter rests
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.selectNextElement()
        await vm.auditionTask?.value

        #expect(fake.recordedScorePreviewCalls.isEmpty)
    }

    @Test func `deleteSelection does not audition`() async {
        let fake = FakePlaybackController()
        let vm = makeViewModel(playback: fake)
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))

        vm.deleteSelection()
        await vm.auditionTask?.value

        #expect(fake.recordedScorePreviewCalls.isEmpty)
        #expect(vm.auditionTask == nil)
    }

    @Test func `ops are safe and audition is a no-op when no playback controller is injected`() {
        let vm = makeViewModel(playback: nil)
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.inputPitch(letter: "c")

        #expect(vm.auditionTask == nil)
    }
}
