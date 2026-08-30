import ReaderInteractionCore
import Testing

/// The bubble's placement arithmetic, which SwiftUI's overlay and Compose's overlay both call rather than restate.
struct ReaderHintBubbleLayoutTests {
    private let viewportWidth: Double = 400
    private let viewportHeight: Double = 900

    private func frame(anchorX: Double, width: Double = 44, target: ReaderHintTarget) -> ReaderHintBubbleFrame {
        ReaderHintBubbleLayout.frame(
            anchor: ReaderHintRect(x: anchorX, y: 100, width: width, height: 44),
            target: target,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
        )
    }

    @Test func `a centered anchor gets a centered card and a straight caret`() {
        let result = frame(anchorX: viewportWidth / 2 - 22, target: .annotationButton)

        #expect(result.caretDX == 0)
        #expect(result.originX == (viewportWidth - result.width) / 2)
    }

    @Test func `the card stops at the edge margin`() {
        let result = frame(anchorX: 0, target: .annotationButton)

        #expect(result.originX == ReaderHintBubbleLayout.edgeMargin)
    }

    @Test func `the caret keeps tracking a control the card could not follow`() {
        let result = frame(anchorX: viewportWidth - 44, target: .annotationButton)

        // The card is pinned to the right margin, so the caret has to lean toward the control.
        #expect(result.originX == viewportWidth - ReaderHintBubbleLayout.edgeMargin - result.width)
        #expect(result.caretDX > 0)
    }

    @Test func `the caret never reaches a rounded corner`() {
        for anchorX in stride(from: -80.0, through: viewportWidth + 80, by: 20) {
            let result = frame(anchorX: anchorX, target: .annotationButton)
            let limit = result.width / 2 - ReaderHintBubbleLayout.caretInset
            #expect(abs(result.caretDX) <= limit + 0.0001)
        }
    }

    @Test func `a narrow viewport shrinks the card rather than overflowing`() {
        let result = ReaderHintBubbleLayout.frame(
            anchor: ReaderHintRect(x: 10, y: 100, width: 44, height: 44),
            target: .annotationButton,
            viewportWidth: 200,
            viewportHeight: viewportHeight,
        )

        #expect(result.width == 200 - 2 * ReaderHintBubbleLayout.edgeMargin)
    }

    @Test func `top chrome hangs the card below its control and the transport floats above`() {
        let below = frame(anchorX: 100, target: .annotationButton)
        #expect(below.placement == .below)
        #expect(below.edgeY == 144 + ReaderHintBubbleLayout.caretGap)

        let above = frame(anchorX: 100, target: .transportCompact)
        #expect(above.placement == .above)
        #expect(above.edgeY == 100 - ReaderHintBubbleLayout.caretGap)
    }

    @Test func `the pad answers by which half of the screen it is resting in`() {
        let docked = ReaderHintBubbleLayout.frame(
            anchor: ReaderHintRect(x: 0, y: 800, width: 400, height: 90),
            target: .noteInputPad,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
        )
        #expect(docked.placement == .above)

        let raised = ReaderHintBubbleLayout.frame(
            anchor: ReaderHintRect(x: 0, y: 20, width: 400, height: 90),
            target: .noteInputPad,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
        )
        #expect(raised.placement == .below)
    }
}
