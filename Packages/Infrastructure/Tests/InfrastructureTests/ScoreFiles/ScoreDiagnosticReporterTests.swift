import Foundation
@testable import ScoreFiles
import Testing

struct ScoreDiagnosticReporterTests {
    @Test func `records only warnings, not info`() throws {
        let fake = FakeCrashReporter()
        ScoreDiagnosticReporter(crashReporter: fake).report([
            ScoreParseDiagnostic(severity: .warning, code: "a", message: "m1", location: nil),
            ScoreParseDiagnostic(severity: .info, code: "b", message: "m2", location: nil),
        ])
        #expect(fake.recordedErrors.count == 1)
        let first = try #require(fake.recordedErrors.first)
        #expect((first as NSError).domain == "a")
    }

    @Test func `dedupes by code within one parse`() {
        let fake = FakeCrashReporter()
        ScoreDiagnosticReporter(crashReporter: fake).report([
            ScoreParseDiagnostic(severity: .warning, code: "a", message: "m", location: nil),
            ScoreParseDiagnostic(severity: .warning, code: "a", message: "m", location: "elsewhere"),
        ])
        #expect(fake.recordedErrors.count == 1)
    }

    @Test func `caps at ten distinct codes`() {
        let fake = FakeCrashReporter()
        let many = (0 ..< 25).map {
            ScoreParseDiagnostic(severity: .warning, code: "code.\($0)", message: "m", location: nil)
        }
        ScoreDiagnosticReporter(crashReporter: fake).report(many)
        #expect(fake.recordedErrors.count == 10)
    }

    @Test func `empty diagnostics record nothing`() {
        let fake = FakeCrashReporter()
        ScoreDiagnosticReporter(crashReporter: fake).report([])
        #expect(fake.recordedErrors.isEmpty)
    }
}
