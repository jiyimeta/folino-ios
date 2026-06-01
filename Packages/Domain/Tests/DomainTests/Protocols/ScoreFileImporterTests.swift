@testable import Domain
import Foundation
import Testing

private final class FakeImporter: ScoreFileImporter {
    func prepareImport(sourceURL: URL) throws -> ImportPlan {
        ImportPlan(
            sourceURL: sourceURL,
            stagedURL: URL(fileURLWithPath: "/tmp/staged.mid"),
            format: .midi,
            summary: ScoreFileSummary(
                title: "x", composer: nil, instrumentationSummary: "Piano",
                lengthBeats: 4, defaultTempoBpm: 120, primaryKey: nil,
            ),
            contentHash: "deadbeef",
            sizeBytes: 1,
            duplicates: [],
        )
    }

    func commitImport(_ plan: ImportPlan, decision: ImportDecision) throws -> ScoreItem {
        ScoreItem(
            title: plan.summary.title ?? "Untitled",
            composer: plan.summary.composer,
            instrumentationSummary: plan.summary.instrumentationSummary,
            localFileName: "x.mid",
            contentHash: plan.contentHash,
            sizeBytes: plan.sizeBytes,
            lengthBeats: plan.summary.lengthBeats,
            defaultTempoBpm: plan.summary.defaultTempoBpm,
            primaryKey: plan.summary.primaryKey,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
    }
}

struct ScoreFileImporterTests {
    @Test func `import plan is hashable and sendable`() {
        let plan = ImportPlan(
            sourceURL: URL(fileURLWithPath: "/tmp/x.mid"),
            stagedURL: URL(fileURLWithPath: "/tmp/staged-x.mid"),
            format: .midi,
            summary: ScoreFileSummary(
                title: nil, composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            ),
            contentHash: "h",
            sizeBytes: 0,
            duplicates: [],
        )
        var set: Set<ImportPlan> = []
        set.insert(plan)
        #expect(set.contains(plan))
    }

    @Test func `import decision is hashable`() {
        let id = ScoreItemID()
        let decisions: Set<ImportDecision> = [.importAsNew, .openExisting(id), .openExisting(id)]
        #expect(decisions.count == 2)
    }

    @Test func `fake importer prepare returns zero duplicates`() async throws {
        let importer: any ScoreFileImporter = FakeImporter()
        let plan = try await importer.prepareImport(sourceURL: URL(fileURLWithPath: "/tmp/x.mid"))
        #expect(plan.duplicates.isEmpty)
    }

    @Test func `score file summary carries credit fields`() {
        let summary = ScoreFileSummary(
            title: "T",
            composer: "C",
            arranger: "A",
            lyricist: "L",
            copyright: "©",
            instrumentationSummary: "",
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
        )
        #expect(summary.arranger == "A")
        #expect(summary.lyricist == "L")
        #expect(summary.copyright == "©")
    }
}
