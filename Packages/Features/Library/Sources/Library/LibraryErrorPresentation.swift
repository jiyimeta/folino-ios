import Domain
import LibraryLogic
import SwiftUI

extension LibraryError {
    /// Localized message shown by SwiftUI Views. Lives in the iOS Library target because LibraryLogic must remain
    /// Foundation-only.
    public var displayMessage: LocalizedStringKey {
        switch self {
        case .domain(.unsupportedFormat):
            "library.import.error.unsupported"
        case .domain(.scoreParseFailed):
            "library.import.error.invalidFile"
        case .domain(.persistenceFailed):
            "library.import.error.saveFailed"
        case let .domain(.scoreFileNotFound(name)):
            LocalizedStringKey("Score file not found: \(name)")
        case let .domain(.scoreWriteFailed(reason)):
            LocalizedStringKey("Could not write score file: \(reason)")
        case let .domain(.syncFailed(reason)):
            LocalizedStringKey("Sync failed: \(reason)")
        case let .domain(.audioEngineFailed(reason)):
            LocalizedStringKey("Audio engine error: \(reason)")
        case let .domain(other):
            // TODO: add localized keys for any new DomainError cases added in future
            LocalizedStringKey("\(other)")
        case let .underlying(message):
            LocalizedStringKey(message)
        }
    }
}
