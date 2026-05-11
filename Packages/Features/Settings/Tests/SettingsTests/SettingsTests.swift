@testable import Settings
import Testing

struct SettingsSmokeTests {
    @Test func `module links`() {
        #expect(SettingsModule.isLinked)
    }
}
