import Foundation

/// Outcome of `ScoreFileImporter.prepareImport`. Carries everything the
/// commit step needs (summary, hash, size) plus the duplicate list so the
/// Feature layer can render a confirmation dialog without a re-read.
///
/// `stagedURL` points at a copy of the source bytes inside a sandbox the
/// app fully owns (e.g., `URL.temporaryDirectory`). `commitImport` works
/// from `stagedURL` so it does not depend on the original URL's security
/// scope, which is one-shot for URLs delivered via `.onOpenURL`. The
/// `sourceURL` is retained only for diagnostics and the title fallback.
public struct ImportPlan: Hashable, Sendable {
    public let sourceURL: URL
    public let stagedURL: URL
    public let format: ScoreFormat
    public let summary: ScoreFileSummary
    public let contentHash: String
    public let sizeBytes: Int64
    public let duplicates: [ScoreItem]

    public init(
        sourceURL: URL,
        stagedURL: URL,
        format: ScoreFormat,
        summary: ScoreFileSummary,
        contentHash: String,
        sizeBytes: Int64,
        duplicates: [ScoreItem]
    ) {
        self.sourceURL = sourceURL
        self.stagedURL = stagedURL
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
