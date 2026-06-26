import Testing
@testable import UtilityCore

struct AnalyticsNoopTests {
    @Test func `noop accepts events and properties without crashing`() {
        let analytics: any Analytics = NoopAnalytics()
        analytics.setCollectionEnabled(true)
        analytics.log(AnalyticsEvent(name: "test_event", parameters: ["k": .string("v")]))
        analytics.setUserProperty("page", for: AnalyticsUserProperty(name: "layout_mode"))
        // No assertion needed: the test passes if these calls compile and don't trap.
    }
}
