import Foundation

/// Snapshot of the CloudKit sync engine's state, exposed via an
/// `AsyncStream` so UI can drive a status indicator.
public enum CloudSyncState: Sendable, Equatable {
    case idle
    case syncing
    case failed(error: String)
    case unavailable
}

/// Drives CloudKit Private Database sync of `ScoreItem`, `Tag`, `Playlist`,
/// `AnnotationLayer`, and `PlaybackPreferences`. Always-local invariant
/// (`docs/product/feasibility.md` D4) lives in the Infrastructure
/// implementation — this protocol does not expose any toggle for eviction.
public protocol CloudSync: Sendable {
    /// Start the sync engine. Idempotent.
    func start() async
    /// Stop the sync engine.
    func stop() async
    /// Force a sync cycle now (UI "Sync now" affordance).
    func syncNow() async throws
    /// Stream of state transitions.
    var state: AsyncStream<CloudSyncState> { get }
}
