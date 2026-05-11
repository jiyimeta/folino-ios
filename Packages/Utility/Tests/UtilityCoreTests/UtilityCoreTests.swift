import Testing
@testable import UtilityCore

struct UtilityCoreSmokeTests {
    @Test func `module links`() {
        #expect(UtilityCoreModule.isLinked)
    }
}
