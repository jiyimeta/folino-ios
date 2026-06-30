import Foundation
import UtilityCore

/// Captures non-fatal errors recorded by the code under test, so import-failure tests can assert a Crashlytics
/// non-fatal was recorded without a real crash SDK. Mutated only on the main actor in tests, hence `@unchecked
/// Sendable`.
final class SpyCrashReporter: CrashReporter, @unchecked Sendable {
    private(set) var recordedErrors: [Error] = []
    private(set) var messages: [String] = []

    func setCollectionEnabled(_: Bool) {}
    func log(_ message: String) {
        messages.append(message)
    }

    func record(error: Error) {
        recordedErrors.append(error)
    }
}
