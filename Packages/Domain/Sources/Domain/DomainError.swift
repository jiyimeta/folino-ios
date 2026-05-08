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
            String(
                localized: "domain.error.scoreFileNotFound",
                defaultValue: "Score file not found: \(name)",
                bundle: .module
            )
        case let .unsupportedFormat(ext):
            String(
                localized: "domain.error.unsupportedFormat",
                defaultValue: "Unsupported file format: \(ext)",
                bundle: .module
            )
        case let .scoreParseFailed(reason):
            String(
                localized: "domain.error.scoreParseFailed",
                defaultValue: "Could not parse score file: \(reason)",
                bundle: .module
            )
        case let .scoreWriteFailed(reason):
            String(
                localized: "domain.error.scoreWriteFailed",
                defaultValue: "Could not write score file: \(reason)",
                bundle: .module
            )
        case let .soundfontDownloadFailed(key):
            String(
                localized: "domain.error.soundfontDownloadFailed",
                defaultValue: "Failed to download SoundFont (bank \(key.bank), program \(key.program))",
                bundle: .module
            )
        case let .persistenceFailed(reason):
            String(
                localized: "domain.error.persistenceFailed",
                defaultValue: "Library save failed: \(reason)",
                bundle: .module
            )
        case let .syncFailed(reason):
            String(
                localized: "domain.error.syncFailed",
                defaultValue: "Sync failed: \(reason)",
                bundle: .module
            )
        case let .audioEngineFailed(reason):
            String(
                localized: "domain.error.audioEngineFailed",
                defaultValue: "Audio engine error: \(reason)",
                bundle: .module
            )
        }
    }
}
