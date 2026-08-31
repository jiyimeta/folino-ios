import Domain
import Foundation

/// `LocalizedError` conformance for `DomainError` lives here in the iOS app target so the Domain module stays platform-
/// neutral (free of Apple-only `String(localized:defaultValue:bundle:)`). The localized strings ship with the app's
/// main bundle — kept byte-identical to the previous Domain-side implementation. UI surfaces in App pick up these
/// translations through the protocol cast (`error as? LocalizedError`); the linker keeps this extension visible at
/// runtime for all callers that share the app process.
extension DomainError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .scoreFileNotFound(name):
            String(
                localized: "domain.error.scoreFileNotFound",
                defaultValue: "Score file not found: \(name)",
                bundle: .main,
            )
        case let .unsupportedFormat(ext):
            String(
                localized: "domain.error.unsupportedFormat",
                defaultValue: "Unsupported file format: \(ext)",
                bundle: .main,
            )
        case let .scoreParseFailed(reason):
            String(
                localized: "domain.error.scoreParseFailed",
                defaultValue: "Could not parse score file: \(reason)",
                bundle: .main,
            )
        case let .scoreWriteFailed(reason):
            String(
                localized: "domain.error.scoreWriteFailed",
                defaultValue: "Could not write score file: \(reason)",
                bundle: .main,
            )
        case let .persistenceFailed(reason):
            String(
                localized: "domain.error.persistenceFailed",
                defaultValue: "Library save failed: \(reason)",
                bundle: .main,
            )
        case let .syncFailed(reason):
            String(
                localized: "domain.error.syncFailed",
                defaultValue: "Sync failed: \(reason)",
                bundle: .main,
            )
        case let .audioEngineFailed(reason):
            String(
                localized: "domain.error.audioEngineFailed",
                defaultValue: "Audio engine error: \(reason)",
                bundle: .main,
            )
        }
    }
}
