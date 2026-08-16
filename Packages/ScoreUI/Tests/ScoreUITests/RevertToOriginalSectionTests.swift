import Domain
@testable import ScoreUI
import Testing

@Suite("Revert section visibility")
struct RevertToOriginalSectionTests {
    private func item(originalFileName: String?) -> ScoreItem {
        var item = ScoreItem(
            title: "t",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "ID.mscz",
            contentHash: "c",
            sizeBytes: 1,
            lengthBeats: 1,
            defaultTempoBpm: 60,
            primaryKey: nil,
            addedAt: .distantPast,
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        item.originalFileName = originalFileName
        item.originalProvenance = originalFileName == nil ? nil : .importTime
        return item
    }

    @Test func `the section is hidden for a score that was never edited`() {
        #expect(item(originalFileName: nil).canRevertToOriginal == false)
    }

    @Test func `the section is shown once an original exists`() {
        #expect(item(originalFileName: "ID.original.mscz").canRevertToOriginal)
    }
}
