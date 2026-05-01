@testable import Domain
import Foundation
import Testing

@Suite struct ScoreItemTests {
    private func sample() -> ScoreItem {
        ScoreItem(
            id: ScoreItemID(),
            title: "Prelude in C",
            composer: "J. S. Bach",
            instrumentationSummary: "Piano",
            format: .mscz,
            localFileName: "prelude.mscz",
            sizeBytes: 8192,
            lengthBeats: 56,
            defaultTempoBpm: 72,
            primaryKey: "C major",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false
        )
    }

    @Test func roundTripsThroughCodable() throws {
        let item = sample()
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ScoreItem.self, from: data)
        #expect(decoded == item)
    }

    @Test func canHoldOptionalMetadata() {
        let item = ScoreItem(
            id: ScoreItemID(),
            title: "Untitled",
            composer: nil,
            instrumentationSummary: nil,
            format: .midi,
            localFileName: "x.mid",
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false
        )
        #expect(item.composer == nil)
        #expect(item.primaryKey == nil)
    }

    @Test func conformsToIdentifiable() {
        let item = sample()
        let _: ScoreItemID = item.id
    }

    @Test func tagIDsAreOrderIndependent() {
        let t1 = TagID()
        let t2 = TagID()
        let base = sample()
        let a = base.with(tagIDs: [t1, t2])
        let b = base.with(tagIDs: [t2, t1])
        // Same id (since `with` keeps id), same tag set → equal.
        #expect(a == b)
    }
}

extension ScoreItem {
    fileprivate func with(tagIDs: Set<TagID>) -> ScoreItem {
        ScoreItem(
            id: id,
            title: title,
            composer: composer,
            instrumentationSummary: instrumentationSummary,
            format: format,
            localFileName: localFileName,
            sizeBytes: sizeBytes,
            lengthBeats: lengthBeats,
            defaultTempoBpm: defaultTempoBpm,
            primaryKey: primaryKey,
            addedAt: addedAt,
            lastOpenedAt: lastOpenedAt,
            tagIDs: tagIDs,
            isFavorite: isFavorite
        )
    }
}
