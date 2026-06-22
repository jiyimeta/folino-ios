import Foundation

/// Persistence façade for `AnnotationLayer`s. There is at most one layer per score item; this protocol exposes a
/// CRUD-by-score-id interface.
public protocol AnnotationStore: Sendable {
    func annotationLayer(forScoreItem id: ScoreItemID) async throws -> AnnotationLayer?
    func saveAnnotationLayer(_ layer: AnnotationLayer) async throws
    func deleteAnnotationLayer(forScoreItem id: ScoreItemID) async throws
}
