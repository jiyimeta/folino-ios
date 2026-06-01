import Foundation

/// Identifiable payload that drives a share-sheet presentation. Replaces the per-view-model `ShareTarget` so Library
/// and Reader present `ActivityViewControllerRepresentable` with one shared type.
public struct ScoreShareTarget: Identifiable, Equatable {
    public let id: UUID
    public let urls: [URL]
    public init(urls: [URL]) {
        id = UUID()
        self.urls = urls
    }
}
