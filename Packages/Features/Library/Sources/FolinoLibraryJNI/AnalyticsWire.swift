import Wirelet

/// One analytics parameter, projected across the JNI boundary. `kind` discriminates which payload field carries the
/// value — 0 = string (`stringValue`), 1 = long (`longValue`), 2 = double (`doubleValue`), 3 = bool (`boolValue`) —
/// mirroring iOS `AnalyticsValue`. The Kotlin side reads `kind` to pick the matching `Bundle.putX`.
@WireFormat
public struct AnalyticsParamWire: Equatable, Sendable {
    public var key: String
    public var kind: Int32
    public var stringValue: String
    public var longValue: Int32
    public var doubleValue: Double
    public var boolValue: Bool

    public init(
        key: String,
        kind: Int32,
        stringValue: String = "",
        longValue: Int32 = 0,
        doubleValue: Double = 0,
        boolValue: Bool = false,
    ) {
        self.key = key
        self.kind = kind
        self.stringValue = stringValue
        self.longValue = longValue
        self.doubleValue = doubleValue
        self.boolValue = boolValue
    }
}

/// A wire-ready analytics event: a name plus its low-cardinality parameters. Built by `AnalyticsBridge` from the
/// SHARED Domain/UtilityCore catalog so iOS and Android emit byte-identical event names + parameter keys.
@WireFormat
public struct AnalyticsEventWire: Equatable, Sendable {
    public var name: String
    public var params: [AnalyticsParamWire]

    public init(name: String, params: [AnalyticsParamWire]) {
        self.name = name
        self.params = params
    }
}
