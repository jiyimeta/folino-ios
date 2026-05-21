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
        case let .domain(other):
            LocalizedStringKey(other.errorDescription ?? "\(other)")
        case let .underlying(message):
            LocalizedStringKey(message)
        }
    }
}
