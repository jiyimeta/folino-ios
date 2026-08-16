import Domain
import Foundation

// The companion hand-off's no-op default (`NoopVocalTunerHandoff`) lives in Domain, not here — both Library and
// Reader want the same default, so it is defined once and re-exported as `public` from `Domain`.

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

/// Inert default for `ReaderViewModel.originalStore`. Previews and tests that don't exercise revert / discard get
/// this; production injects the real `LiveScoreOriginalStore` from the App composition root.
struct NoopScoreOriginalStore: ScoreOriginalStore {
    // swiftlint:disable:next async_without_await
    func captureOriginalIfNeeded(for item: ScoreItem) async throws -> ScoreItem {
        item
    }

    // swiftlint:disable:next async_without_await
    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo _: Bool) async throws -> ScoreItem {
        item
    }

    // swiftlint:disable:next async_without_await
    func discardOriginal(for item: ScoreItem) async throws -> ScoreItem {
        item
    }
}

/// Inert backing store for the default `ReaderViewModel.annotationCoordinator`. Production injects
/// `LiveAnnotationStore` (which conforms to `AnnotationBlobStore`) from the App composition root; previews and tests
/// that don't exercise annotations get this no-op, so the coordinator has a valid store with nothing behind it.
struct NoopAnnotationBlobStore: AnnotationBlobStore {
    // swiftlint:disable:next async_without_await
    func load(scoreID _: ScoreItemID) async throws -> Data? {
        nil
    }

    // swiftlint:disable:next async_without_await
    func save(scoreID _: ScoreItemID, updatedAt _: Date, payload _: Data) async throws {}
    // swiftlint:disable:next async_without_await
    func delete(scoreID _: ScoreItemID) async throws {}
}
