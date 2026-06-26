import UtilityCore

/// Records every `AnalyticsEvent` (and user property) the code under test logs, so feature tests can assert the event
/// name and parameters without a real analytics SDK. Mutated only on the main actor in tests, hence `@unchecked
/// Sendable`.
final class SpyAnalytics: Analytics, @unchecked Sendable {
    private(set) var events: [AnalyticsEvent] = []
    private(set) var userProperties: [(value: String?, property: AnalyticsUserProperty)] = []
    private(set) var collectionEnabled = true

    func setCollectionEnabled(_ enabled: Bool) {
        collectionEnabled = enabled
    }

    func log(_ event: AnalyticsEvent) {
        events.append(event)
    }

    func setUserProperty(_ value: String?, for property: AnalyticsUserProperty) {
        userProperties.append((value, property))
    }

    /// First logged event with the given name, or nil. Convenience for assertions.
    func event(named name: String) -> AnalyticsEvent? {
        events.first { $0.name == name }
    }
}
