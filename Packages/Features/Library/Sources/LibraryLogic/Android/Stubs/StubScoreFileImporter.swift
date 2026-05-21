#if os(Android)
import Domain
import Foundation

/// Stub file importer for the Android JNI pilot. prepareImport returns a minimal ImportPlan with
/// no duplicates; commitImport returns a stub ScoreItem without touching any real file system.
public struct StubScoreFileImporter: ScoreFileImporter {
    public init() {}

    public func prepareImport(sourceURL: URL) throws -> ImportPlan {
        let summary = ScoreFileSummary(
            title: sourceURL.deletingPathExtension().lastPathComponent,
            composer: nil,
            instrumentationSummary: "Unknown",
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
        )
        return ImportPlan(
            sourceURL: sourceURL,
            stagedURL: sourceURL,
            format: .mscx,
            summary: summary,
            contentHash: "stub-import-hash",
            sizeBytes: 0,
            duplicates: [],
        )
    }

    public func commitImport(_ plan: ImportPlan, decision: ImportDecision) throws -> ScoreItem {
        ScoreItem(
            title: plan.summary.title ?? plan.sourceURL.deletingPathExtension().lastPathComponent,
            composer: plan.summary.composer,
            instrumentationSummary: plan.summary.instrumentationSummary,
            localFileName: plan.sourceURL.lastPathComponent,
            contentHash: plan.contentHash,
            sizeBytes: plan.sizeBytes,
            lengthBeats: plan.summary.lengthBeats,
            defaultTempoBpm: plan.summary.defaultTempoBpm,
            primaryKey: plan.summary.primaryKey,
            addedAt: Date(),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
    }
}
#endif
