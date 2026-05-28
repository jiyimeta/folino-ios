import Foundation

/// Shared error type for the Domain layer. Infrastructure adapters either throw these directly or wrap their own errors
/// as a `DomainError` at the Domain boundary. Equatable so tests can compare expected errors directly.
///
/// `LocalizedError` conformance lives in the iOS UI layer (`App/DomainError+LocalizedError.swift`), keeping Domain free
/// of Apple-only `String(localized:defaultValue:bundle:)` and cross-platform compilable as-is.
public enum DomainError: Error, Sendable, Equatable {
    case scoreFileNotFound(name: String)
    case unsupportedFormat(String)
    case scoreParseFailed(reason: String)
    case scoreWriteFailed(reason: String)
    case persistenceFailed(reason: String)
    case syncFailed(reason: String)
    case audioEngineFailed(reason: String)
}
