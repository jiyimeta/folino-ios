import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@Suite @MainActor
struct ReaderViewModelManualCursorTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "T", composer: nil, instrumentationSummary: nil,
            localFileName: "t.mscx", contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    @Test func setManualCursorUpdatesPlaybackCursorImmediately() {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        let cursor = ScoreCursor.beat(measureIndex: 3, tickInMeasure: 120)
        vm.setManualCursor(cursor)
        #expect(vm.playbackCursor == cursor)
    }

    @Test func setManualCursorForwardsToControllerExactlyOnce() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        let cursor = ScoreCursor.beat(measureIndex: 1, tickInMeasure: 0)
        vm.setManualCursor(cursor)
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(controller.recordedSetCursorCalls == [cursor])
    }

    @Test func setManualCursorWithNoControllerOnlyUpdatesLocalCursor() {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: nil
        )
        let cursor = ScoreCursor.beat(measureIndex: 7, tickInMeasure: 0)
        vm.setManualCursor(cursor)
        #expect(vm.playbackCursor == cursor)
    }
}
