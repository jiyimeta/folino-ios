import Domain

/// Abstraction the edit-info sheet uses instead of a concrete feature view model. Library and Reader view models both
/// conform, supplying the file-metadata read (for credit pre-fill) and the persist step.
@MainActor
public protocol ScoreInfoEditing {
    /// On-disk credit metaTags for pre-fill. Returns nil if the file can't be parsed (editing still proceeds).
    func loadFileMetadata(for item: ScoreItem) async -> ScoreFileMetadata?
    /// Apply edited fields and persist. Title is required (trimmed, non-empty); empties are stored as `""`.
    func saveMetadata(_ item: ScoreItem, fields: EditableScoreInfo) async
    /// Restores the score's original bytes. `restoringScoreInfo` additionally re-reads the credit fields from that
    /// file; content-derived fields come from it either way.
    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) async
}
