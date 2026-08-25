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
    func `appendMeasure grows the score by one bar`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests())

        viewModel.appendMeasure()

        #expect(viewModel.measureCount == 3)
    }

    @Test
    func `insert before the selected bar shifts it right`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests())
        viewModel.select(.rest(EditorFixtures.restID(measure: 1, element: 0)))

        viewModel.insertMeasureBeforeTarget()

        #expect(viewModel.measureCount == 3)
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
