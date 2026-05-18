import Foundation

/// Snapshot view of the device's current network reachability. The Reader uses it to decide whether a "loading sounds"
/// wait is going to make progress — if the box is offline, downloads can't complete and the user sees a dedicated
/// offline message instead of an open-ended loading spinner.
public protocol NetworkReachability: Sendable {
    /// `true` when the device currently has a usable network path. Reflects the latest `NWPathMonitor` snapshot — may
    /// briefly lag the actual transition, but resolves within milliseconds.
    func isOnline() async -> Bool
}
