import Wirelet

/// Wire projection of the download state for Compose. Wirelet's `@WireletObservable` cannot bridge a Swift enum
/// with associated values, so the store exposes these flattened fields and the Kotlin UI reconstructs a sealed
/// state from `statusRaw` + `progress` + `failureReason`. `isOptedIn` is folded in here because the observable
/// emitter does not project a bare `Bool` stored property on the store.
///
/// `statusRaw` is one of: "idle", "downloading", "downloaded", "failed".
@WireFormat
public struct SoundfontStateWire: Equatable, Sendable {
    public var statusRaw: String
    public var progress: Double // meaningful when statusRaw == "downloading"; else 0
    public var failureReason: String // non-empty when statusRaw == "failed"; else ""
    public var isOptedIn: Bool

    public init(statusRaw: String, progress: Double, failureReason: String, isOptedIn: Bool) {
        self.statusRaw = statusRaw
        self.progress = progress
        self.failureReason = failureReason
        self.isOptedIn = isOptedIn
    }
}
