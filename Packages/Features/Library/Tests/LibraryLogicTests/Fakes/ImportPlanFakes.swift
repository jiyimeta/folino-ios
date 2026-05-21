import Domain
import Foundation

extension ScoreItem {
    static func makeFake(
        title: String = "Fake",
        contentHash: String = UUID().uuidString,
    ) -> ScoreItem {
        ScoreItem(
            id: ScoreItemID(),
            title: title,
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "\(UUID().uuidString).mscx",
            contentHash: contentHash,
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
    }
}

extension ImportPlan {
    static func makeFake(duplicates: [ScoreItem] = []) -> ImportPlan {
        ImportPlan(
            sourceURL: URL(filePath: "/tmp/fake.mscx"),
            stagedURL: URL(filePath: "/tmp/staged-fake.mscx"),
            format: .mscx,
            summary: ScoreFileSummary(
                title: "Fake", composer: nil,
                instrumentationSummary: "", lengthBeats: 0,
                defaultTempoBpm: 120, primaryKey: nil,
            ),
            contentHash: "fakehash",
            sizeBytes: 0,
            duplicates: duplicates,
        )
    }
}
