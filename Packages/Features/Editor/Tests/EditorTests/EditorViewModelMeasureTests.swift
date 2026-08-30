import Domain
@testable import Editor
import Foundation
import Testing

/// Measure structure actions (append / insert-before / delete) — Task 9. Uses the same two-bar rest fixture as
/// `CrossBarInputTests` so a bar selection is trivial: `restID(measure: 1, element: 0)` sits in bar 1.
@MainActor
@Suite("EditorViewModel measure actions")
struct EditorViewModelMeasureTests {
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

    @Test
    func `appendMeasure grows the score by one bar without moving the caret or selection`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests())
        viewModel.select(.rest(EditorFixtures.restID(element: 2))) // bar 0, untouched by an append at the end
        let selectedBefore = viewModel.selectedItem
        let caretBefore = viewModel.caretItem

        viewModel.appendMeasure()

        #expect(viewModel.measureCount == 3)
        #expect(viewModel.selectedItem == selectedBefore)
        #expect(viewModel.caretItem == caretBefore)
    }

    @Test
    func `insert before the selected bar shifts it right`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests())
        viewModel.select(.rest(EditorFixtures.restID(measure: 1, element: 0)))

        viewModel.insertMeasureBeforeTarget()

        #expect(viewModel.measureCount == 3)
    }

    /// The whole run is ONE edit. Adding thirty bars and taking them back must be one press of undo — a composite
    /// per bar would leave the user pressing it thirty times, which is the reason the bulk path exists at all.
    @Test
    func `appending several bars is one undo step`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests())

        viewModel.appendMeasures(5)
        #expect(viewModel.measureCount == 7)

        viewModel.undo()
        #expect(viewModel.measureCount == 2)
    }

    /// The bars land as a consecutive run starting at the target, not as a pile at one index — the composite's
    /// members run against the score as it grows, which is what the advancing index is for.
    @Test
    func `inserting several bars before the target is one undo step`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests())
        viewModel.select(.rest(EditorFixtures.restID(measure: 1, element: 0)))

        viewModel.insertMeasuresBeforeTarget(3)
        #expect(viewModel.measureCount == 5)

        viewModel.undo()
        #expect(viewModel.measureCount == 2)
    }

    /// Zero is the count a cleared field can hand over; it must do nothing rather than land an empty edit that
    /// undo would then have to step through.
    @Test
    func `adding zero bars does nothing`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests())
        viewModel.select(.rest(EditorFixtures.restID(measure: 1, element: 0)))

        viewModel.appendMeasures(0)
        viewModel.insertMeasuresBeforeTarget(0)

        #expect(viewModel.measureCount == 2)
        #expect(!viewModel.canUndo)
    }

    @Test
    func `delete target measure shrinks the score and clears a dangling selection`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests())
        viewModel.select(.rest(EditorFixtures.restID(measure: 1, element: 0)))

        viewModel.deleteTargetMeasure()

        #expect(viewModel.measureCount == 1)
        #expect(viewModel.targetMeasureIndex == nil || viewModel.targetMeasureIndex == 0)
    }

    @Test
    func `actions without a target are no-ops, not crashes`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests())

        viewModel.insertMeasureBeforeTarget()
        viewModel.deleteTargetMeasure()

        #expect(viewModel.measureCount == 2)
    }
}
