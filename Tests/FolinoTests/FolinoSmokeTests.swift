@testable import folino
import Testing

struct FolinoSmokeTests {
    @Test func `app target links`() {
        // Compile-time check: if this file builds, the test target is wired
        // against the app target correctly.
        #expect(2 + 2 == 4)
    }
}
