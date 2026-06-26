import FirebaseAnalytics
import Foundation
import UtilityCore

/// `Analytics` backed by Firebase Analytics. The only place in folino that imports `FirebaseAnalytics`.
/// Logging is gated locally (in addition to the SDK-level disable) as defense-in-depth: events are dropped
/// before reaching Firebase when the user has opted out.
public struct FirebaseAnalyticsClient: UtilityCore.Analytics {
    private let flag: AnalyticsEnabledFlag
    private let _logEvent: @Sendable (String, [String: Any]) -> Void
    private let _setUserProperty: @Sendable (String?, String) -> Void
    private let _sdkSetCollectionEnabled: @Sendable (Bool) -> Void

    /// Seam constructor for tests. Production code uses `make(collectionEnabled:)`.
    init(
        logEvent: @escaping @Sendable (String, [String: Any]) -> Void,
        setUserProperty: @escaping @Sendable (String?, String) -> Void,
    ) {
        flag = AnalyticsEnabledFlag(isEnabled: false)
        _logEvent = logEvent
        _setUserProperty = setUserProperty
        _sdkSetCollectionEnabled = { _ in }
    }

    private init(
        flag: AnalyticsEnabledFlag,
        logEvent: @escaping @Sendable (String, [String: Any]) -> Void,
        setUserProperty: @escaping @Sendable (String?, String) -> Void,
        sdkSetCollectionEnabled: @escaping @Sendable (Bool) -> Void,
    ) {
        self.flag = flag
        _logEvent = logEvent
        _setUserProperty = setUserProperty
        _sdkSetCollectionEnabled = sdkSetCollectionEnabled
    }

    /// Production constructor. Assumes `FirebaseApp.configure()` already ran (owned by the crash reporter).
    /// Does NOT call `FirebaseApp.configure()` itself.
    @MainActor
    public static func make(collectionEnabled: Bool) -> FirebaseAnalyticsClient {
        let client = FirebaseAnalyticsClient(
            flag: AnalyticsEnabledFlag(isEnabled: collectionEnabled),
            logEvent: { FirebaseAnalytics.Analytics.logEvent($0, parameters: $1) },
            setUserProperty: { FirebaseAnalytics.Analytics.setUserProperty($0, forName: $1) },
            sdkSetCollectionEnabled: { FirebaseAnalytics.Analytics.setAnalyticsCollectionEnabled($0) },
        )
        // Apply the persisted preference to the SDK at startup so the SDK and the local gate agree.
        FirebaseAnalytics.Analytics.setAnalyticsCollectionEnabled(collectionEnabled)
        return client
    }

    public func setCollectionEnabled(_ on: Bool) {
        flag.isEnabled = on
        _sdkSetCollectionEnabled(on)
    }

    public func log(_ event: AnalyticsEvent) {
        guard flag.isEnabled else { return }
        _logEvent(event.name, event.parameters.mapValues(\.firebaseValue))
    }

    public func setUserProperty(_ value: String?, for property: AnalyticsUserProperty) {
        guard flag.isEnabled else { return }
        _setUserProperty(value, property.name)
    }
}

/// Thread-safe boolean gate for local event suppression.
final class AnalyticsEnabledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _isEnabled: Bool

    init(isEnabled: Bool) {
        _isEnabled = isEnabled
    }

    var isEnabled: Bool {
        get { lock.withLock { _isEnabled } }
        set { lock.withLock { _isEnabled = newValue } }
    }
}

extension AnalyticsValue {
    fileprivate var firebaseValue: Any {
        switch self {
        case let .string(s): s
        case let .int(i): i
        case let .double(d): d
        case let .bool(b): b
        }
    }
}
