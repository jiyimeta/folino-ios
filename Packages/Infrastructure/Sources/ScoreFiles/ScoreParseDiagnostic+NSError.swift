import Foundation

extension ScoreParseDiagnostic {
    /// Maps the diagnostic to an `NSError` shaped for Crashlytics non-fatal grouping: `domain` is the stable `code`
    /// so all occurrences of one anomaly collapse into a single issue, and the full `message`/`location` ride in
    /// `userInfo` with no length limit (the reason Crashlytics beats Analytics for this).
    ///
    /// Privacy boundary: only `code`, `message`, `location`, and `severity` are included — never a filename, file
    /// path, or file contents.
    func asNSError() -> NSError {
        let severityValue = switch severity {
        case .warning: "warning"
        case .info: "info"
        }
        return NSError(domain: code, code: 0, userInfo: [
            NSLocalizedDescriptionKey: message,
            "diagnosticCode": code,
            "severity": severityValue,
            "location": location ?? "",
        ])
    }
}
