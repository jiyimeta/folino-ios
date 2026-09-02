import Domain
import Foundation

extension LibraryViewModel {
    /// True when something is armed that only a Library presentation host can surface — the duplicate-import prompt
    /// or the error alert. Both are `internal`, so the App layer cannot read them directly; this is the one bit it
    /// needs.
    ///
    /// **Why the App needs it at all.** On macOS the import alerts are mounted in exactly one place (the library
    /// browser's `libraryRootPresentations`), but File ▸ Import can be invoked from a score window with the browser
    /// closed — and then `startImport` arms one of these and returns with nothing on screen to answer it.
    /// `MacShellView.importAction` reads this right after awaiting `startImport` and summons the browser, so the
    /// single host exists to present. See that method's doc comment for why a second host was not the answer.
    ///
    /// Lives in this file rather than beside the properties it reads only because `LibraryViewModel.swift` is at
    /// SwiftLint's 400-line file budget.
    public var hasPendingImportPrompt: Bool {
        duplicatePrompt != nil || currentError != nil
    }

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
