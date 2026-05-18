import Foundation
import Testing

/// Polls a predicate up to ~2s, yielding 20ms between checks so an async observer task can run and update the
/// predicate's inputs. Records a Swift Testing issue (test failure) on timeout but returns normally so subsequent
/// assertions can still produce useful failure messages.
@MainActor
func waitFor(
    timeout: Duration = .seconds(2),
    _ predicate: @MainActor () -> Bool,
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("predicate never satisfied within \(timeout)")
}
