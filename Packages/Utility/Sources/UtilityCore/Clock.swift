import Foundation

/// Ambient wall-clock abstraction. Production callers depend on `any Clock` instead of `Date.now` so tests can inject
/// deterministic time.
///
/// Implementations must be safe to call from any actor.
public protocol Clock: Sendable {
    func now() -> Date
}

/// Default production `Clock` that returns `Date.now`.
public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date {
        .now
    }
}
