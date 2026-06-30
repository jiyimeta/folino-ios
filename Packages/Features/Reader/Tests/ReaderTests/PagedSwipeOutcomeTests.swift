import CoreGraphics
@testable import Reader
import Testing

struct PagedSwipeOutcomeTests {
    private func outcome(_ tx: CGFloat, _ pred: CGFloat, first: Bool = false, last: Bool = false) -> PageSwipeOutcome {
        PagedReaderNavigation.outcome(
            translationX: tx,
            predictedEndX: pred,
            viewportWidth: 1000,
            isAtFirstPage: first,
            isAtLastPage: last,
        )
    }

    @Test func `commits next past threshold`() {
        #expect(outcome(-350, -350) == .commitNext)
    }

    @Test func `commits previous past threshold`() {
        #expect(outcome(350, 350) == .commitPrevious)
    }

    @Test func `cancels below threshold`() {
        #expect(outcome(100, 100) == .cancel)
    }

    @Test func `fling commits via predicted end`() {
        #expect(outcome(50, -400) == .commitNext)
    }

    @Test func `cancels off first edge`() {
        #expect(outcome(400, 400, first: true) == .cancel)
    }

    @Test func `cancels off last edge`() {
        #expect(outcome(-400, -400, last: true) == .cancel)
    }

    @Test func `damping asymptotes below half viewport`() {
        let d = PagedReaderNavigation.dampedTranslation(raw: 100_000, viewportWidth: 1000)
        #expect(d < 1000 && d > 400)
    }
}
