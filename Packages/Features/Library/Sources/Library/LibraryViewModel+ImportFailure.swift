import Domain
import Foundation

extension LibraryViewModel {
    /// Record an import failure as both an analytics event and a Crashlytics non-fatal. The `reason` is bucketed to a
    /// stable low-cardinality label so analytics never carries a raw error string.
    func logImportFailed(format: String, error: Error) {
        crashReporter.record(error: error)
        analytics.log(.scoreImportFailed(format: format, reason: Self.importFailureReason(error)))
    }

    static func importFailureReason(_ error: Error) -> String {
        guard let domain = error as? DomainError else { return "other" }
        switch domain {
        case .scoreFileNotFound: return "file_not_found"
        case .unsupportedFormat: return "unsupported_format"
        case .scoreParseFailed: return "parse_failed"
        case .scoreWriteFailed: return "write_failed"
        case .persistenceFailed: return "persistence_failed"
        case .syncFailed: return "sync_failed"
        case .audioEngineFailed: return "audio_engine_failed"
        }
    }
}
