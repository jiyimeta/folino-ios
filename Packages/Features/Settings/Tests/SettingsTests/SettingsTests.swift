@testable import Settings
import Testing

@Suite struct SettingsSmokeTests {
    @Test func moduleLinks() {
        #expect(SettingsModule.isLinked)
    }
}
