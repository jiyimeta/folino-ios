import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderPlaybackSessionAuditionTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "T", composer: nil, instrumentationSummary: nil,
            localFileName: "t.mscx", contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    private static func makeViewModel(
        controller: FakePlaybackController,
    ) -> ReaderViewModel {
        let item = makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        return ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
    }

    private static let noteID = NoteID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
        measureIndex: 2, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
    )

    @Test func `tapping a note while stopped auditions it once for half a second`() async {
        let controller = FakePlaybackController()
        let vm = Self.makeViewModel(controller: controller)
        vm.playbackSession.setManualCursor(.item(.note(Self.noteID)))
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(controller.recordedPreviewCalls.count == 1)
        #expect(controller.recordedPreviewCalls.first?.noteID == Self.noteID)
        #expect(controller.recordedPreviewCalls.first?.duration == 0.5)
    }

    @Test func `tapping a rest while stopped auditions nothing`() async {
        let controller = FakePlaybackController()
        let vm = Self.makeViewModel(controller: controller)
        let restID = RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 2, voiceIndex: 0, elementIndex: 1,
        )
        vm.playbackSession.setManualCursor(.item(.rest(restID)))
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(controller.recordedPreviewCalls.isEmpty)
    }

    @Test func `tapping a note while playing does not audition`() async {
        let controller = FakePlaybackController()
        let vm = Self.makeViewModel(controller: controller)
        vm.playbackSession.startObservingCursor()
        controller.emitIsPlaying(true)
        vm.playbackSession.setManualCursor(.item(.note(Self.noteID)))
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(controller.recordedPreviewCalls.isEmpty)
        // The cursor is still moved during playback — only the audition is suppressed.
        #expect(controller.recordedSetCursorCalls == [.item(.note(Self.noteID))])
    }
}
