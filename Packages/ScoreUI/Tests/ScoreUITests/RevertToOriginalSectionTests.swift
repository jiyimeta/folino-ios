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

    /// Exercises `RevertToOriginalSection.shouldShow(_:)` — the gate `EditScoreInfoSheet` actually calls — rather
    /// than the Domain property it happens to be built from. `ScoreItem.canRevertToOriginal` is already covered by
    /// `RevertPolicyTests`; asserting it again here (as this suite used to) would stay green even if
    /// `EditScoreInfoSheet` stopped calling `shouldShow` at all (Important 6 review fix).
    @Test func `the section is hidden for a score that was never edited`() {
        #expect(RevertToOriginalSection.shouldShow(item(originalFileName: nil)) == false)
    }

    @Test func `the section is shown once an original exists`() {
        #expect(RevertToOriginalSection.shouldShow(item(originalFileName: "ID.original.mscz")))
    }
}
