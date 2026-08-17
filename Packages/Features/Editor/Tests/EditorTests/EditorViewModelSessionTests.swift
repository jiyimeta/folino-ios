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
            playback: nil,
        )
    }

    @Test func `beginSession arms the editor and applyCommand mutates + notifies`() throws {
        let vm = makeViewModel()
        var changedScores: [Score] = []
        vm.onScoreChanged = { changedScores.append($0) }
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        #expect(vm.isSessionActive)
        #expect(vm.generation == 0)
        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))
        #expect(vm.generation == 1)
        #expect(changedScores.count == 1)
        let note = try #require(vm.score?[EditorFixtures.noteID(element: 1)])
        #expect(note.pitch == 60)
    }

    @Test func `undo and redo round trip and bump generation`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))
        #expect(vm.canUndo && !vm.canRedo)
        vm.undo()
        #expect(!vm.canUndo && vm.canRedo)
        #expect(vm.score == EditorFixtures.fourQuarterRests())
        vm.redo()
        #expect(vm.canUndo && !vm.canRedo)
        #expect(vm.generation == 3)
    }

    @Test func `appliedEditCount bumps only on applyCommand, never on undo or redo`() {
        // Task 16 review fix: the system-undo bridge (EditorChromeView) must re-register its UndoManager trampoline
        // only on a genuinely NEW edit. `generation` bumps on undo/redo too (the Reader's layout key needs that),
        // so the bridge needs a separate signal that stays flat across undo/redo.
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        #expect(vm.appliedEditCount == 0)

        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))
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
        vm.applyCommand(SetNotePitch(at: EditorFixtures.noteID(element: 1), pitch: 61, tpc: 21))
        #expect(vm.generation == 0)
        #expect(vm.score == EditorFixtures.fourQuarterRests())
    }

    @Test func `applyCommand re-derives selection onto the newly input note`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 1)))
        #expect(vm.selection == .single(.note(EditorFixtures.noteID(element: 1))))
    }
}
