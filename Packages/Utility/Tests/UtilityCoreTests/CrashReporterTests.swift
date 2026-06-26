import Foundation
import Testing
@testable import UtilityCore

struct CrashReporterTests {
    @Test func `noop reporter satisfies the protocol and ignores all calls`() {
        let reporter: any CrashReporter = NoopCrashReporter()
        // None of these should crash or have observable effect.
        reporter.setCollectionEnabled(true)
        reporter.setCollectionEnabled(false)
        reporter.log("hello")
        reporter.record(error: CocoaError(.fileNoSuchFile))
    }
}
