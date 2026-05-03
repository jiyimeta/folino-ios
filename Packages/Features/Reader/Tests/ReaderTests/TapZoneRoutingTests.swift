@testable import Reader
import Testing

@Suite struct TapZoneRoutingTests {
    @Test func leftQuarterIsPrev() {
        #expect(tapZone(forX: 0, width: 1000) == .prev)
        #expect(tapZone(forX: 100, width: 1000) == .prev)
        #expect(tapZone(forX: 249, width: 1000) == .prev)
    }

    @Test func centerHalfIsChrome() {
        #expect(tapZone(forX: 250, width: 1000) == .chrome)
        #expect(tapZone(forX: 500, width: 1000) == .chrome)
        #expect(tapZone(forX: 749, width: 1000) == .chrome)
    }

    @Test func rightQuarterIsNext() {
        #expect(tapZone(forX: 750, width: 1000) == .next)
        #expect(tapZone(forX: 999, width: 1000) == .next)
        #expect(tapZone(forX: 1000, width: 1000) == .next)
    }

    @Test func zeroOrNegativeWidthFallsBackToChrome() {
        #expect(tapZone(forX: 50, width: 0) == .chrome)
        #expect(tapZone(forX: 50, width: -10) == .chrome)
    }
}
