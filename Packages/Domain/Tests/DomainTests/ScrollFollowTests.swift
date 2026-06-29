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

struct ScrollOffsetPinningSystemTopTests {
    private let viewport = 100.0
    private let topInset = 10.0

    @Test func `does not move when system is visible and lookahead is within the viewport`() {
        // View [0,100]; system [60,80] fully visible; lookahead bottom 90 within view.
        let r = scrollOffsetPinningSystemTop(
            current: 0, systemMin: 60, systemMax: 80, lookaheadMax: 90, viewport: viewport, topInset: topInset,
        )
        #expect(r == 0)
    }

    @Test func `lookahead below the viewport pins the visible system to the top`() {
        // View [0,100]; system [60,80] still fully visible, but lookahead bottom 130 is below → snap system to top.
        let r = scrollOffsetPinningSystemTop(
            current: 0, systemMin: 60, systemMax: 80, lookaheadMax: 130, viewport: viewport, topInset: topInset,
        )
        #expect(r == 50) // systemMin - topInset
    }

    @Test func `system below the viewport pins it to the top (tall-system re-pin)`() {
        // View [0,100]; system [140,210] is below the viewport → pin its top.
        let r = scrollOffsetPinningSystemTop(
            current: 0, systemMin: 140, systemMax: 210, lookaheadMax: 210, viewport: viewport, topInset: topInset,
        )
        #expect(r == 130) // max(0, 140 - 10)
    }

    @Test func `system above the viewport pins it to the top (backward seek)`() {
        // View [200,300]; system [150,170] is above → scroll up and pin.
        let r = scrollOffsetPinningSystemTop(
            current: 200, systemMin: 150, systemMax: 170, lookaheadMax: 170, viewport: viewport, topInset: topInset,
        )
        #expect(r == 140) // max(0, 150 - 10)
    }

    @Test func `clamps the leading edge at zero`() {
        // System near the very top; pinning would go negative → clamp to 0.
        let r = scrollOffsetPinningSystemTop(
            current: 50, systemMin: 5, systemMax: 25, lookaheadMax: 200, viewport: viewport, topInset: topInset,
        )
        #expect(r == 0) // max(0, 5 - 10)
    }

    @Test func `pins the top when the system is taller than the viewport`() {
        // System [40,260] taller than the 100 viewport → pin its top regardless.
        let r = scrollOffsetPinningSystemTop(
            current: 0, systemMin: 40, systemMax: 260, lookaheadMax: 260, viewport: viewport, topInset: topInset,
        )
        #expect(r == 30) // max(0, 40 - 10)
    }

    @Test func `stays put once the system is pinned and the lookahead is back in view`() {
        // System pinned: view [50,150]; system [60,80] visible; lookahead bottom 140 within view → no move.
        let r = scrollOffsetPinningSystemTop(
            current: 50, systemMin: 60, systemMax: 80, lookaheadMax: 140, viewport: viewport, topInset: topInset,
        )
        #expect(r == 50)
    }
}

struct HorizontalMeasureScrollOffsetTests {
    @Test func `fully visible measure does not move`() {
        // measure [120,200] inside view [100,500] (viewport 400) → stay.
        let r = horizontalMeasureScrollOffset(
            current: 100, measureMin: 120, measureMax: 200, viewport: 400, pad: 8,
        )
        #expect(r == 100)
    }

    @Test func `measure right of viewport parks leading edge`() {
        // measure [600,700] right of view [100,500] → park min-pad = 592.
        let r = horizontalMeasureScrollOffset(
            current: 100, measureMin: 600, measureMax: 700, viewport: 400, pad: 8,
        )
        #expect(r == 592)
    }

    @Test func `measure left of viewport parks leading edge clamped to zero`() {
        // measure [4,40] left of view [100,500] → park min-pad = max(0,-4) = 0.
        let r = horizontalMeasureScrollOffset(
            current: 100, measureMin: 4, measureMax: 40, viewport: 400, pad: 8,
        )
        #expect(r == 0)
    }

    @Test func `measure wider than viewport parks leading edge`() {
        // measure [600,1200] wider than viewport 400, not fully visible → 592.
        let r = horizontalMeasureScrollOffset(
            current: 100, measureMin: 600, measureMax: 1200, viewport: 400, pad: 8,
        )
        #expect(r == 592)
    }
}

struct ReaderShouldFollowPlaybackTests {
    @Test func `follows everything while enabled`() {
        #expect(readerShouldFollowPlayback(autoFollowEnabled: true, isPlaybackDriven: true))
        #expect(readerShouldFollowPlayback(autoFollowEnabled: true, isPlaybackDriven: false))
    }

    @Test func `suppresses only playback-driven follow when disabled`() {
        #expect(readerShouldFollowPlayback(autoFollowEnabled: false, isPlaybackDriven: true) == false)
    }

    @Test func `keeps manual navigation in view when disabled`() {
        // Manual seek / scrub (anchor nil → not playback-driven) still follows so the target stays on screen.
        #expect(readerShouldFollowPlayback(autoFollowEnabled: false, isPlaybackDriven: false))
    }
}
