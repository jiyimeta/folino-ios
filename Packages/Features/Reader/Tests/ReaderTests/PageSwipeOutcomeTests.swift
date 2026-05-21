import CoreGraphics
@testable import Reader
import Testing

struct PageSwipeOutcomeTests {
    private let viewport: CGFloat = 400

    @Test func `left drag past 30 percent commits next`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: -125, predictedEndX: -125,
            viewportWidth: viewport,
            isAtFirstPage: false, isAtLastPage: false,
        )
        #expect(outcome == .commitNext)
    }

    @Test func `right drag past 30 percent commits previous`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: 125, predictedEndX: 125,
            viewportWidth: viewport,
            isAtFirstPage: false, isAtLastPage: false,
        )
        #expect(outcome == .commitPrevious)
    }

    @Test func `under-threshold drag cancels`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: -80, predictedEndX: -80,
            viewportWidth: viewport,
            isAtFirstPage: false, isAtLastPage: false,
        )
        #expect(outcome == .cancel)
    }

    @Test func `fling above threshold commits even when translation below`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: -40, predictedEndX: -300,
            viewportWidth: viewport,
            isAtFirstPage: false, isAtLastPage: false,
        )
        #expect(outcome == .commitNext)
    }

    @Test func `right fling above threshold from small drag commits previous`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: 40, predictedEndX: 300,
            viewportWidth: viewport,
            isAtFirstPage: false, isAtLastPage: false,
        )
        #expect(outcome == .commitPrevious)
    }

    @Test func `right drag at first page cancels regardless of distance`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: 250, predictedEndX: 400,
            viewportWidth: viewport,
            isAtFirstPage: true, isAtLastPage: false,
        )
        #expect(outcome == .cancel)
    }

    @Test func `left drag at last page cancels regardless of distance`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: -250, predictedEndX: -400,
            viewportWidth: viewport,
            isAtFirstPage: false, isAtLastPage: true,
        )
        #expect(outcome == .cancel)
    }

    @Test func `at first page, left commit still works`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: -125, predictedEndX: -125,
            viewportWidth: viewport,
            isAtFirstPage: true, isAtLastPage: false,
        )
        #expect(outcome == .commitNext)
    }

    @Test func `at last page, right commit still works`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: 125, predictedEndX: 125,
            viewportWidth: viewport,
            isAtFirstPage: false, isAtLastPage: true,
        )
        #expect(outcome == .commitPrevious)
    }

    @Test func `zero viewport width defensively cancels`() {
        let outcome = PagedScoreContainer.outcome(
            translationX: -200, predictedEndX: -400,
            viewportWidth: 0,
            isAtFirstPage: false, isAtLastPage: false,
        )
        #expect(outcome == .cancel)
    }
}
