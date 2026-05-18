import Domain
import Foundation
import Network

/// `NWPathMonitor`-backed reachability snapshot. The Reader queries `isOnline()` at play time to differentiate a
/// slow-but-progressing download from a no-network stall.
///
/// The monitor runs for the lifetime of the actor; callers normally hold a single instance for the whole app session
/// (constructed in `AppBootstrap`). Cancelling/dropping the actor stops the monitor.
public actor LiveNetworkReachability: Domain.NetworkReachability {
    private let monitor: NWPathMonitor
    /// Latest path snapshot from `NWPathMonitor`. Defaults to `.satisfied` so a freshly constructed reachability —
    /// before the first callback fires — reports "online" rather than briefly flagging the user as offline on launch.
    /// The monitor's first update overrides this within a few milliseconds of `start(queue:)`.
    private var lastStatus: NWPath.Status = .satisfied

    public init() {
        monitor = NWPathMonitor()
        let monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let status = path.status
            Task { await self.update(status: status) }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    deinit {
        monitor.cancel()
    }

    public func isOnline() -> Bool {
        lastStatus == .satisfied
    }

    private func update(status: NWPath.Status) {
        lastStatus = status
    }
}
