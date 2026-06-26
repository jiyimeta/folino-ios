@testable import Domain
import Testing

struct PrivacySettingsKeyTests {
    /// The raw string is user state. Renaming it silently resets every installed user's opt-out preference, so this
    /// test guards the literal the way `ReaderGlobalSettingsKey.metronomeEnabled` is guarded by comment.
    @Test func `crash reporting key is the stable literal`() {
        #expect(PrivacySettingsKey.crashReportingEnabled == "privacyCrashReportingEnabled")
    }

    @Test func `analytics key is stable raw string`() {
        #expect(PrivacySettingsKey.analyticsEnabled == "privacyAnalyticsEnabled")
    }
}
