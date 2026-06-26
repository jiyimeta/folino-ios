@testable import Analytics
import Foundation
import Testing
import UtilityCore

struct FirebaseAnalyticsClientGatingTests {
    @Test func `disabled client drops events and properties`() {
        let loggedEvents = EventRecorder()
        let setProps = EventRecorder()
        let client = FirebaseAnalyticsClient(
            logEvent: { name, _ in loggedEvents.append(name) },
            setUserProperty: { _, name in setProps.append(name) },
        )
        client.setCollectionEnabled(false)
        client.log(AnalyticsEvent(name: "score_imported"))
        client.setUserProperty("page", for: .layoutMode)
        #expect(loggedEvents.items.isEmpty)
        #expect(setProps.items.isEmpty)
    }

    @Test func `enabled client forwards events`() {
        let loggedEvents = EventRecorder()
        let client = FirebaseAnalyticsClient(
            logEvent: { name, _ in loggedEvents.append(name) },
            setUserProperty: { _, _ in },
        )
        client.setCollectionEnabled(true)
        client.log(AnalyticsEvent(name: "score_imported"))
        #expect(loggedEvents.items == ["score_imported"])
    }
}

/// Thread-safe string accumulator for capturing closure calls in @Sendable contexts.
private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String] = []

    var items: [String] {
        lock.withLock { _items }
    }

    func append(_ item: String) {
        lock.withLock { _items.append(item) }
    }
}
