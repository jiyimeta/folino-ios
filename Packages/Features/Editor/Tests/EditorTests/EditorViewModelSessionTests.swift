import Domain
@testable import Editor
import Foundation
import SheetMusicUI
import Testing

@MainActor
@Suite("EditorViewModel session")
struct EditorViewModelSessionTests {
    private func makeViewModel() -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: URL(filePath: "/tmp"),
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
    }

    @Test func `beginSession arms the editor and apply mutates + notifies`() throws {
        let vm = makeViewModel()
        var changedScores: [Score] = []
        vm.onScoreChanged = { changedScores.append($0) }
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        #expect(vm.isSessionActive)
        #expect(vm.generation == 0)
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        #expect(vm.generation == 1)
        #expect(changedScores.count == 1)
        let note = try #require(vm.score?[EditorFixtures.noteID(element: 1)])
        #expect(note.pitch == 60)
    }

    @Test func `undo and redo round trip and bump generation`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        #expect(vm.canUndo && !vm.canRedo)
        vm.undo()
        #expect(!vm.canUndo && vm.canRedo)
        #expect(vm.score == EditorFixtures.fourQuarterRests())
        vm.redo()
        #expect(vm.canUndo && !vm.canRedo)
        #expect(vm.generation == 3)
    }

    @Test func `appliedEditCount bumps only on apply, never on undo or redo`() {
        // The system-undo bridge (EditorChromeView) must re-register its UndoManager trampoline
        // only on a genuinely NEW edit. `generation` bumps on undo/redo too (the Reader's layout key needs that),
        // so the bridge needs a separate signal that stays flat across undo/redo.
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        #expect(vm.appliedEditCount == 0)

        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        #expect(vm.appliedEditCount == 1)
        #expect(vm.generation == 1)

        vm.undo()
        #expect(vm.appliedEditCount == 1)
        #expect(vm.generation == 2)

        vm.redo()
        #expect(vm.appliedEditCount == 1)
        #expect(vm.generation == 3)
    }

    @Test func `invalid edit is swallowed and mutates nothing`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        // Element 1 is a rest, not a note — SetNotePitch must refuse; the VM must not bump generation.
        vm.apply(.setNotePitch(at: EditorFixtures.noteID(element: 1), pitch: 61, tpc: 21, accidental: nil))
        #expect(vm.generation == 0)
        #expect(vm.score == EditorFixtures.fourQuarterRests())
    }

    @Test func `apply re-derives selection onto the newly input note`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 1)))
        #expect(vm.selection == .single(.note(EditorFixtures.noteID(element: 1))))
    }
}
