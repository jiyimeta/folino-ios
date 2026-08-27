import Domain
import Foundation

/// Maps a Reader load error to its user-facing string. A top-level helper rather than a method on
/// `ReaderViewModel`, so any Screen that surfaces such an error can reach it without holding the view model.
func describeReaderError(_ error: Error) -> String {
    if let domain = error as? DomainError {
        switch domain {
        case .scoreFileNotFound:
            return String(localized: "reader.error.fileMissing", bundle: .module)
        case .scoreParseFailed:
            return String(localized: "reader.error.corrupted", bundle: .module)
        case .unsupportedFormat:
            return String(localized: "reader.error.cannotOpen.unsupportedType", bundle: .module)
        case let .scoreWriteFailed(reason):
            return String(
                localized: "reader.error.fallback.scoreWriteFailed",
                defaultValue: "Could not write score file: \(reason)",
                bundle: .module,
            )
        case let .persistenceFailed(reason):
            return String(
                localized: "reader.error.fallback.persistenceFailed",
                defaultValue: "Library save failed: \(reason)",
                bundle: .module,
            )
        case let .syncFailed(reason):
            return String(
                localized: "reader.error.fallback.syncFailed",
                defaultValue: "Sync failed: \(reason)",
                bundle: .module,
            )
        case let .audioEngineFailed(reason):
            return String(
                localized: "reader.error.fallback.audioEngineFailed",
                defaultValue: "Audio engine error: \(reason)",
                bundle: .module,
            )
        }
    }
    return (error as NSError).localizedDescription
}
