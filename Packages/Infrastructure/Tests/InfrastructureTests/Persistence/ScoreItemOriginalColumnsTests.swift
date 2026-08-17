import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite("score_items original columns")
struct ScoreItemOriginalColumnsTests {
    private func item(originalFileName: String?, originalContentHash: String?) -> ScoreItem {
        var item = ScoreItem(
            title: "t",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "ID.mscz",
            contentHash: "current",
            sizeBytes: 1,
            lengthBeats: 1,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        item.originalFileName = originalFileName
        item.originalContentHash = originalContentHash
        item.originalProvenance = originalFileName == nil ? nil : .importTime
        return item
    }

    @Test func `the record round-trips the three columns`() throws {
        let subject = item(originalFileName: "ID.original.mscz", originalContentHash: "orig")
        let record = ScoreItemRecord(domain: subject)
        let restored = try record.toDomain(tagIDs: [])
        #expect(restored.originalFileName == "ID.original.mscz")
        #expect(restored.originalContentHash == "orig")
        #expect(restored.originalProvenance == .importTime)
    }

    @Test func `an unrecognised provenance decodes as nil`() throws {
        var record = ScoreItemRecord(domain: item(originalFileName: "ID.original.mscz", originalContentHash: "o"))
        record.originalProvenance = "somethingElse"
        #expect(try record.toDomain(tagIDs: []).originalProvenance == nil)
    }

    @Test func `every file backing a row is listed for deletion`() {
        var record = ScoreItemRecord(domain: item(originalFileName: "ID.original.mscz", originalContentHash: "o"))
        record.sourcePDFFileName = "ID.pdf"
        let files = LiveScoreLibraryRepository.filesBackingRow(record)
        #expect(Set(files) == ["ID.mscz", "ID.pdf", "ID.original.mscz"])
    }

    @Test func `an original that is the item's own file is not listed twice`() {
        var record = ScoreItemRecord(domain: item(originalFileName: nil, originalContentHash: nil))
        record.originalFileName = "ID.mscz"
        #expect(LiveScoreLibraryRepository.filesBackingRow(record) == ["ID.mscz"])
    }
}
