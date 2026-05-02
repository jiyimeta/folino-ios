import Foundation

/// Outcome of `ScoreFileImporter.prepareImport`. Carries everything the
/// commit step needs (summary, hash, size) plus the duplicate list so the
/// Feature layer can render a confirmation dialog without a re-read.
public struct ImportPlan: Hashable, Sendable {
    public let sourceURL: URL
    public let format: ScoreFormat
    public let summary: ScoreFileSummary
    public let contentHash: String
    public let sizeBytes: Int64
    public let duplicates: [ScoreItem]

    public init(
        sourceURL: URL,
        format: ScoreFormat,
        summary: ScoreFileSummary,
        contentHash: String,
        sizeBytes: Int64,
        duplicates: [ScoreItem]
    ) {
        self.sourceURL = sourceURL
        self.format = format
        self.summary = summary
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.duplicates = duplicates
    }
}

/// What the user (or auto-resolution) decided to do with a prepared `ImportPlan`.
public enum ImportDecision: Hashable, Sendable {
    case importAsNew
    case openExisting(ScoreItemID)
}

/// Two-stage importer: `prepareImport` does all reads (hash, summary, dup
/// query) and returns the plan; `commitImport` does the write (file copy +
/// repository row) only after the decision is known. A user cancelling the
/// dup dialog simply discards the plan — no I/O has happened yet.
public protocol ScoreFileImporter: Sendable {
    func prepareImport(sourceURL: URL) async throws -> ImportPlan
    func commitImport(_ plan: ImportPlan, decision: ImportDecision) async throws -> ScoreItem
}
