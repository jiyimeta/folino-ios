import Domain
@testable import Editor
import Foundation
import SheetMusicUI
import Testing

/// Task 9 — audition: a fire-and-forget pitch preview on note input and pitch change (spec §5.6). `audition(_:)`
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
