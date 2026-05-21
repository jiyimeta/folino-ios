import Domain
import Foundation

/// Non-localized error value type for the Library feature. Carries enough
/// information for the UI layer (any platform) to choose a localized
/// message. `LibraryLogic` does not depend on any localization mechanism.
public enum LibraryError: Sendable, Equatable {
    case domain(DomainError)
    case underlying(message: String)

    public static func from(_ error: Error) -> LibraryError {
        if let domain = error as? DomainError {
            return .domain(domain)
        }
        return .underlying(message: (error as NSError).localizedDescription)
    }
}
