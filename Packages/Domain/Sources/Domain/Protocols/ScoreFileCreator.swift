/// Creates a brand-new score in the library from an in-memory `Score` — the scratch-creation counterpart of
/// `ScoreFileImporter`. No duplicate detection: a freshly built score is never a duplicate.
public protocol ScoreFileCreator: Sendable {
    /// Writes `score` as a new `.mscx` file in the library and registers its row. Returns the created item.
    func createScore(_ score: Score) async throws -> ScoreItem
}
