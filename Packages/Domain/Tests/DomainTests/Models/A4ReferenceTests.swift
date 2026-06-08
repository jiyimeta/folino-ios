@testable import Domain
import Foundation
import Testing

struct A4ReferenceTests {
    @Test func `cents at 440 is zero`() {
        #expect(abs(A4Reference.cents(forHz: 440)) < 1e-9)
    }

    @Test func `cents 432 is about minus 31 77`() {
        #expect(abs(A4Reference.cents(forHz: 432) - -31.766654) < 1e-3)
    }

    @Test func `effective uses override then global`() {
        #expect(A4Reference.effectiveHz(override: 432, globalDefault: 442) == 432)
        #expect(A4Reference.effectiveHz(override: nil, globalDefault: 442) == 442)
    }

    @Test func `bounds clamp to range`() {
        #expect(A4Reference.clamp(400) == A4Reference.minHz)
        #expect(A4Reference.clamp(500) == A4Reference.maxHz)
    }
}
