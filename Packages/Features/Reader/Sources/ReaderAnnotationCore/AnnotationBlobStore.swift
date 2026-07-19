import Domain
import Foundation

/// The dumb per-score blob store the `AnnotationSaveCoordinator` writes through. Raw payload bytes only — no assembly,
/// no debounce, no empty→delete policy (all of that lives in the coordinator). iOS backs it with GRDB
/// (`LiveAnnotationStore`); Android backs it with Room through a `@WireletProvided` adapter. Keyed by `ScoreItemID`
/// (at most one annotation layer per score).
public protocol AnnotationBlobStore: Sendable {
    /// Raw payload bytes for a score's annotation layer, or `nil` when none is stored.
    func load(scoreID: ScoreItemID) async throws -> Data?
    /// Upsert the score's annotation layer: its payload bytes + the layer's updated-at timestamp.
    func save(scoreID: ScoreItemID, updatedAt: Date, payload: Data) async throws
    /// Remove the score's annotation layer entirely.
    func delete(scoreID: ScoreItemID) async throws
}
