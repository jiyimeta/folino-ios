import Testing
@testable import UtilityCore

@Suite struct UtilityCoreSmokeTests {
    @Test func moduleLinks() {
        #expect(UtilityCoreModule.isLinked)
    }
}
