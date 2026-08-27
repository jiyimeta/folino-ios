import Domain
import Foundation

/// Maps a `LibraryViewModel` error to its user-facing string. A top-level helper rather than a method on the view
/// model, so any Screen that surfaces such an error can reach it without holding the view model.
func describeLibraryError(_ error: Error) -> String {
    if let domain = error as? DomainError {
        switch domain {
        case .unsupportedFormat:
            return String(localized: "library.import.error.unsupported", bundle: .module)
        case .scoreParseFailed:
            return String(localized: "library.import.error.invalidFile", bundle: .module)
        case .persistenceFailed:
            return String(localized: "library.import.error.saveFailed", bundle: .module)
        case let .scoreFileNotFound(name):
            return String(
                localized: "library.error.fallback.scoreFileNotFound",
                defaultValue: "Score file not found: \(name)",
                bundle: .module,
            )
        case let .scoreWriteFailed(reason):
            return String(
                localized: "library.error.fallback.scoreWriteFailed",
                defaultValue: "Could not write score file: \(reason)",
                bundle: .module,
            )
        case let .syncFailed(reason):
            return String(
                localized: "library.error.fallback.syncFailed",
                defaultValue: "Sync failed: \(reason)",
                bundle: .module,
            )
        case let .audioEngineFailed(reason):
            return String(
                localized: "library.error.fallback.audioEngineFailed",
                defaultValue: "Audio engine error: \(reason)",
                bundle: .module,
            )
        }
    }
    return (error as NSError).localizedDescription
}
