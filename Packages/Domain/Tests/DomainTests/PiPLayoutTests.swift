@testable import Domain
import Foundation
import Testing

struct PiPLayoutTests {
    private let numerator = 6.0
    // iOS bounds.
    private let iosMin = 1.0
    private let iosMax = 6.0
    // Android bounds (OS hard limit on PiP aspect).
    private let andMin = 1.0
    private let andMax = 2.34

    @Test func `single staff hits the platform max (iOS wide, Android clamped)`() {
        #expect(
            pipWindowAspect(staffCount: 1, aspectNumerator: numerator, minAspect: iosMin, maxAspect: iosMax) == 6.0,
        )
        #expect(
            pipWindowAspect(staffCount: 1, aspectNumerator: numerator, minAspect: andMin, maxAspect: andMax) == 2.34,
        )
    }

    @Test func `two staves: iOS 3.0, Android clamped to 2.34`() {
        #expect(
            pipWindowAspect(staffCount: 2, aspectNumerator: numerator, minAspect: iosMin, maxAspect: iosMax) == 3.0,
        )
        #expect(
            pipWindowAspect(staffCount: 2, aspectNumerator: numerator, minAspect: andMin, maxAspect: andMax) == 2.34,
        )
    }

    @Test func `three staves land at 2.0 on both platforms`() {
        #expect(pipWindowAspect(staffCount: 3, aspectNumerator: numerator, minAspect: iosMin, maxAspect: iosMax) == 2.0)
        #expect(pipWindowAspect(staffCount: 3, aspectNumerator: numerator, minAspect: andMin, maxAspect: andMax) == 2.0)
    }

    @Test func `six staves clamp at the shared square floor`() {
        #expect(pipWindowAspect(staffCount: 6, aspectNumerator: numerator, minAspect: iosMin, maxAspect: iosMax) == 1.0)
        #expect(pipWindowAspect(staffCount: 6, aspectNumerator: numerator, minAspect: andMin, maxAspect: andMax) == 1.0)
    }

    @Test func `many staves stay clamped at minAspect (never taller than square)`() {
        #expect(
            pipWindowAspect(staffCount: 12, aspectNumerator: numerator, minAspect: iosMin, maxAspect: iosMax) == 1.0,
        )
    }

    @Test func `zero or negative staff count is treated as one`() {
        #expect(
            pipWindowAspect(staffCount: 0, aspectNumerator: numerator, minAspect: andMin, maxAspect: andMax) == 2.34,
        )
        #expect(
            pipWindowAspect(staffCount: -3, aspectNumerator: numerator, minAspect: andMin, maxAspect: andMax) == 2.34,
        )
    }
}
