import Foundation
import UtilityCore

/// Forwards parse diagnostics to crash telemetry. Per-parse policy:
/// - forward only `.warning` (see the spec's "Non-goals: .info" — `.info` has no producers yet and would only add
///   noise);
/// - dedupe by `code` so one file that trips the same anomaly repeatedly reports it once;
/// - cap at `maxPerParse` distinct codes as a flooding safety net.
///
/// No opt-out check here: `CrashReporter.record(error:)` is already a no-op when Crashlytics collection is disabled
/// (`PrivacySettingsKey.crashReportingEnabled == false`), keeping that gate in one place.
struct ScoreDiagnosticReporter {
    let crashReporter: any CrashReporter

    private static let maxPerParse = 10

    func report(_ diagnostics: [ScoreParseDiagnostic]) {
        var seen = Set<String>()
        for diagnostic in diagnostics
            where diagnostic.severity == .warning && seen.insert(diagnostic.code).inserted
        {
            if seen.count > Self.maxPerParse { break }
            crashReporter.record(error: diagnostic.asNSError())
        }
    }
}
