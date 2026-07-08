import Domain
import Foundation

/// Inert `AnnotationStore` for the screenshot scenes. Returns a fixed, pre-authored `AnnotationLayer` (or `nil` for the
/// scenes that show no ink) and ignores all writes — nothing here touches disk or a database. Production injects the
/// real `LiveAnnotationStore` from the App composition root; the screenshot target needs only this static stand-in.
///
/// The `Reader` package's own `NoopAnnotationStore` is `internal`, so the scenes (which use plain `import Reader`, not
/// `@testable`) can't reach it. This fixture conforms to the public Domain protocol directly, mirroring the other
/// `Fixture…` services in this target.
struct FixtureAnnotationStore: AnnotationStore {
    /// The layer every score resolves to. `nil` makes the store inert (the `Reader`/`ABRepeat`/inspector scenes pass no
    /// layer); the annotation scene passes `FixtureInk.layer` so committed ink renders on the score.
    var layer: AnnotationLayer?

    init(layer: AnnotationLayer? = nil) {
        self.layer = layer
    }

    // swiftlint:disable:next async_without_await
    func annotationLayer(forScoreItem _: ScoreItemID) async throws -> AnnotationLayer? {
        layer
    }

    // swiftlint:disable:next async_without_await
    func saveAnnotationLayer(_: AnnotationLayer) async throws {}
    // swiftlint:disable:next async_without_await
    func deleteAnnotationLayer(forScoreItem _: ScoreItemID) async throws {}
}
