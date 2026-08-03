import Domain
import Foundation

/// Inert `AnnotationBlobStore` for the screenshot scenes: every load misses, every write is dropped — nothing here
/// touches disk or a database. Production injects the real `LiveAnnotationStore` from the App composition root; the
/// screenshot target needs only this stand-in.
///
/// No scene renders live ink. The annotation scene shows a real-device capture instead, because PencilKit doesn't
/// composite in the simulator — see `AnnotationScene`.
struct FixtureAnnotationStore: AnnotationBlobStore {
    // swiftlint:disable:next async_without_await
    func load(scoreID _: ScoreItemID) async throws -> Data? {
        nil
    }

    // swiftlint:disable:next async_without_await
    func save(scoreID _: ScoreItemID, updatedAt _: Date, payload _: Data) async throws {}
    // swiftlint:disable:next async_without_await
    func delete(scoreID _: ScoreItemID) async throws {}
}

extension AnnotationSaveCoordinator {
    /// The coordinator every scene hands to `ReaderRootScreen`. Backed by `FixtureAnnotationStore`, so the Reader's
    /// annotation plumbing is wired exactly as in production but persists nothing.
    static var fixture: AnnotationSaveCoordinator {
        AnnotationSaveCoordinator(store: FixtureAnnotationStore())
    }
}
