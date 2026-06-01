import Domain
import Foundation
@testable import Reader
import ScoreUI
import Testing

@MainActor
struct ReaderViewModelShareTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    @Test func `requestShare prepares URL and sets shareTarget`() async {
        let item = Self.makeItem()
        let share = FakeScoreShareService()
        share.preparedURL = URL(filePath: "/tmp/out.pdf")
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: FakeScoreLibraryRepository(),
            gateway: FakeScoreFileGateway(),
            shareService: share,
            scoresDirectory: URL(filePath: "/tmp"),
        )

        await vm.requestShare(format: .pdf)

        #expect(share.prepareCallCount == 1)
        #expect(vm.shareTarget?.urls == [URL(filePath: "/tmp/out.pdf")])
        #expect(vm.isPreparingShare == false)
    }
}
