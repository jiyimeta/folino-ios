@testable import Domain
import Foundation
import Testing

struct ScrollFollowTests {
    private let viewport = 100.0
    private let pad = 8.0

    @Test func `keeps current offset when target is fully visible`() {
        let result = scrollOffsetKeepingInView(
            current: 50, targetMin: 60, targetMax: 80, viewport: viewport, pad: pad,
        )
        #expect(result == 50)
    }

    @Test func `scrolls up with padding when target is above the viewport`() {
        // Viewport shows [50, 150]; target [20, 40] is above.
        let result = scrollOffsetKeepingInView(
            current: 50, targetMin: 20, targetMax: 40, viewport: viewport, pad: pad,
        )
        #expect(result == 12) // targetMin - pad
    }

    @Test func `scrolls down with padding when target is below the viewport`() {
        // Viewport shows [0, 100]; target [180, 200] is below.
        let result = scrollOffsetKeepingInView(
            current: 0, targetMin: 180, targetMax: 200, viewport: viewport, pad: pad,
        )
        #expect(result == 108) // targetMax - viewport + pad
    }

    @Test func `pins target top without pad when taller than viewport`() {
        let result = scrollOffsetKeepingInView(
            current: 0, targetMin: 30, targetMax: 200, viewport: viewport, pad: pad,
        )
        #expect(result == 30) // max(0, targetMin), no pad
    }

    @Test func `clamps the leading edge at zero`() {
        // Target near the very top, current scrolled down; bringing it in would go negative → clamp to 0.
        let result = scrollOffsetKeepingInView(
            current: 30, targetMin: 2, targetMax: 20, viewport: viewport, pad: pad,
        )
        #expect(result == 0) // max(0, 2 - 8)
    }
}
