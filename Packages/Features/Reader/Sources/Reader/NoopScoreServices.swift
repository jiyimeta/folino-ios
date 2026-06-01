import Domain
import Foundation

/// Inert default for `ReaderViewModel.shareService` so previews and tests that don't exercise sharing need no extra
/// argument. Production always injects the real `LiveScoreShareService` from the App composition root.
struct NoopScoreShareService: ScoreShareService {
    // swiftlint:disable:next async_without_await
    func availableFormats(for _: ScoreItem) async -> [ScoreShareFormatOption] {
        []
    }

    // swiftlint:disable:next async_without_await
    func prepareShare(item _: ScoreItem, format _: ScoreShareFormat) async throws -> URL {
        throw DomainError.unsupportedFormat("noop")
    }
}

/// Inert default for `ReaderViewModel.metadataReader`. Production injects the real reader; previews/tests get empty
/// pre-fill.
struct NoopScoreMetadataReading: ScoreMetadataReading {
    // swiftlint:disable:next async_without_await
    func readMetadata(for _: ScoreItem) async throws -> ScoreFileMetadata {
        throw DomainError.unsupportedFormat("noop")
    }
}
