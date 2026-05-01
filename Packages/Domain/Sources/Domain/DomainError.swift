import Foundation

/// Shared error type for the Domain layer. Infrastructure adapters either throw
/// these directly or wrap their own errors as a `DomainError` at the Domain
/// boundary. Equatable so tests can compare expected errors directly.
public enum DomainError: Error, Sendable, Equatable {
    case scoreFileNotFound(name: String)
    case unsupportedFormat(String)
    case scoreParseFailed(reason: String)
    case scoreWriteFailed(reason: String)
    case soundfontDownloadFailed(SoundfontPatchKey)
    case persistenceFailed(reason: String)
    case syncFailed(reason: String)
    case audioEngineFailed(reason: String)
}

extension DomainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .scoreFileNotFound(name):
            "Score file not found: \(name)"
        case let .unsupportedFormat(ext):
            "Unsupported file format: \(ext)"
        case let .scoreParseFailed(reason):
            "Could not parse score file: \(reason)"
        case let .scoreWriteFailed(reason):
            "Could not write score file: \(reason)"
        case let .soundfontDownloadFailed(key):
            "Failed to download SoundFont (bank \(key.bank), program \(key.program))"
        case let .persistenceFailed(reason):
            "Library save failed: \(reason)"
        case let .syncFailed(reason):
            "Sync failed: \(reason)"
        case let .audioEngineFailed(reason):
            "Audio engine error: \(reason)"
        }
    }
}
