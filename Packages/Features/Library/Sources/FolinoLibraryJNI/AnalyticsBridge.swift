import Domain // AnalyticsEvent factories (AnalyticsEvent.settingsOpened())
import Observation
import UtilityCore // AnalyticsEvent, AnalyticsValue (the shared catalog types)
import Wirelet
import WireletObservable

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

/// A wire-ready user-property assignment (name + value). Unused by Task 18's event path; the user-property sync
/// builders that consume it land in Task 19. Declared now so the analytics wire vocabulary is complete in one place.
@WireFormat
public struct AnalyticsPropertyWire: Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Builds `AnalyticsEventWire` payloads for the Android Firebase Analytics client (`AndroidAnalytics.kt`) from the
/// SHARED catalog. Event names, parameter keys, count bucketing, and the `analyticsValue` mappings all live in
/// Domain/UtilityCore — identical to iOS, never reimplemented in Kotlin — so this bridge only marshals an
/// `AnalyticsEvent` into the JNI wire shape. Kotlin owns the actual Firebase SDK call; the bridge is one-directional.
///
/// Stateless by design: no observable stored property, only `@WireletExpose` builder methods. The generated Kotlin
/// `AnalyticsBridgeViewModel` therefore has no `StateFlow` — just the builder methods plus a no-arg `create()`.
/// Task 18 ships exactly one builder (`settingsOpened`); the remaining event + user-property builders land in Task 19.
@WireletObservable
@Observable
public final class AnalyticsBridge {
    public init() {}

    /// Settings screen opened (the Task 18 end-to-end smoke event; iOS logs the same `settings_opened`).
    @WireletExpose
    public func settingsOpened() -> AnalyticsEventWire {
        Self.encode(AnalyticsEvent.settingsOpened())
    }

    /// Marshal a shared `AnalyticsEvent` into the JNI wire shape, mirroring iOS `FirebaseAnalyticsClient`'s
    /// `AnalyticsValue -> Firebase` mapping (.string -> String, .int -> Long, .double -> Double, .bool -> Bool).
    /// All four cases are handled so a future parameter type is never silently dropped — even though today's catalog
    /// only emits `.string` and `.bool`. (`.int` widths beyond Int32 cannot occur today: counts are bucketed to
    /// strings before they reach analytics, so the Int32 wire field is never narrowed in practice.)
    static func encode(_ event: AnalyticsEvent) -> AnalyticsEventWire {
        let params = event.parameters.map { key, value -> AnalyticsParamWire in
            switch value {
            case let .string(s):
                AnalyticsParamWire(key: key, kind: 0, stringValue: s)
            case let .int(i):
                AnalyticsParamWire(key: key, kind: 1, longValue: Int32(truncatingIfNeeded: i))
            case let .double(d):
                AnalyticsParamWire(key: key, kind: 2, doubleValue: d)
            case let .bool(b):
                AnalyticsParamWire(key: key, kind: 3, boolValue: b)
            }
        }
        return AnalyticsEventWire(name: event.name, params: params)
    }
}
