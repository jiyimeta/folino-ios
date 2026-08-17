import Domain
@testable import Editor
import Foundation
import Testing

/// The pad's ← / → keys: step the selection along the voice without aiming a tap at a specific notehead.
@MainActor
@Suite("EditorViewModel navigation")
struct EditorViewModelNavigationTests {
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

    @Test func `steps the selection forward one slot`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.selectNextElement()

        #expect(vm.selectedItem == .rest(EditorFixtures.restID(element: 2)))
    }

    @Test func `steps the selection back one slot`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 2)))

        vm.selectPreviousElement()

        #expect(vm.selectedItem == .rest(EditorFixtures.restID(element: 1)))
    }

    /// Stepping is navigation, not editing: it must not touch the score or the undo stack.
    @Test func `stepping doesn't edit the score`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.selectNextElement()
        vm.selectPreviousElement()

        #expect(vm.generation == 0)
        #expect(vm.appliedEditCount == 0)
        #expect(!vm.canUndo)
    }

    @Test func `holds at the ends instead of deselecting`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))

        vm.selectPreviousElement() // already the first timed slot

        #expect(vm.selectedItem == .rest(EditorFixtures.restID(element: 1)))
    }

    @Test func `does nothing when there is no selection`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())

        vm.selectNextElement()

        #expect(vm.selectedItem == nil)
    }
}
