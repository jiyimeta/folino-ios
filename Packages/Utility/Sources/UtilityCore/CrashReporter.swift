import Foundation

/// Ambient crash-reporting abstraction. Production code depends on `any CrashReporter` rather than a concrete crash SDK
/// so Features stay testable and the SDK import stays in one Infrastructure target.
///
/// Implementations must be safe to call from any actor.
public protocol CrashReporter: Sendable {
    /// Enable or disable crash-data collection. Implementations persist this across launches.
    func setCollectionEnabled(_ enabled: Bool)

    /// Append a breadcrumb-style message to the next crash report, if collection is enabled.
    func log(_ message: String)

    /// Record a non-fatal error.
    func record(error: Error)
}

/// No-op `CrashReporter` for SwiftUI previews and tests. Never touches a crash SDK.
public struct NoopCrashReporter: CrashReporter {
    public init() {}
    public func setCollectionEnabled(_: Bool) {}
    public func log(_: String) {}
    public func record(error _: Error) {}
}
