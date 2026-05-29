import Foundation
import UtilityCore

/// Test double for `CrashReporter`. Records every `record(error:)` call so tests can assert what telemetry was
/// emitted. Thread-safe because `LiveScoreFileGateway` reports from inside a detached task.
final class FakeCrashReporter: CrashReporter, @unchecked Sendable {
    private let lock = NSLock()
    private var _recordedErrors: [Error] = []

    var recordedErrors: [Error] {
        lock.withLock { _recordedErrors }
    }

    func setCollectionEnabled(_: Bool) {}
    func log(_: String) {}

    func record(error: Error) {
        lock.withLock { _recordedErrors.append(error) }
    }
}
