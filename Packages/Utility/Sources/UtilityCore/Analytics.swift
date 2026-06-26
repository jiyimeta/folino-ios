import Foundation

/// A single analytics parameter value. The adapter maps each case to the platform SDK's parameter encoding.
public enum AnalyticsValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

/// Ambient analytics abstraction. Production code depends on `any Analytics` rather than a concrete SDK so Features
/// stay testable and the SDK import stays in one Infrastructure target. Implementations must be safe to call from any
/// actor and must be best-effort: a failed log never throws to the caller.
public protocol Analytics: Sendable {
    /// Enable or disable collection. Implementations persist this across launches and no-op all logging while disabled.
    func setCollectionEnabled(_ enabled: Bool)
    /// Record a single event. No-op when collection is disabled.
    func log(_ event: AnalyticsEvent)
    /// Set (or clear, when `value` is nil) a user property. No-op when collection is disabled.
    func setUserProperty(_ value: String?, for property: AnalyticsUserProperty)
}

/// No-op `Analytics` for SwiftUI previews and tests. Never touches an analytics SDK.
public struct NoopAnalytics: Analytics {
    public init() {}
    public func setCollectionEnabled(_: Bool) {}
    public func log(_: AnalyticsEvent) {}
    public func setUserProperty(_: String?, for _: AnalyticsUserProperty) {}
}
