import Foundation

/// A wire-ready analytics event: a name plus low-cardinality parameters. Features never construct this directly with
/// raw strings — they call the typed factories in `AnalyticsEvent+Factories.swift`, which are the single source of
/// truth for event names and parameter keys (the iOS/Android parity contract).
public struct AnalyticsEvent: Sendable, Equatable {
    public let name: String
    public let parameters: [String: AnalyticsValue]

    public init(name: String, parameters: [String: AnalyticsValue] = [:]) {
        self.name = name
        self.parameters = parameters
    }
}

/// A wire-ready user-property key. Construct via the typed statics in `AnalyticsUserProperty+Keys.swift`.
public struct AnalyticsUserProperty: Sendable, Equatable {
    public let name: String
    public init(name: String) {
        self.name = name
    }
}
