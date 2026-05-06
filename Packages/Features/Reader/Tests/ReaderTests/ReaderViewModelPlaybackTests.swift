import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@Suite @MainActor
struct ReaderViewModelPlaybackTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    private static func makeGateway(score: Score) -> FakeScoreFileGateway {
        FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "Test", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
        )))
    }

    @Test func playbackCursorMirrorsControllerStream() {
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
        vm.startObservingCursor()
        let target = ScoreCursor.beat(measureIndex: 4, tickInMeasure: 240)
        controller.emitCursor(target)
        #expect(vm.playbackCursor == target)

        controller.emitCursor(nil)
        #expect(vm.playbackCursor == nil)
    }

    @Test func togglePlaybackLoadsPlaysThenPauses() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        await vm.togglePlayback()
        #expect(controller.loadCount == 1)
        #expect(controller.playCount == 1)
        #expect(vm.isPlaying)

        await vm.togglePlayback()
        #expect(controller.pauseCount == 1)
        #expect(controller.loadCount == 1) // load only happens once
        #expect(!vm.isPlaying)
    }

    @Test func cancelLoadingSoundfontsAbortsTogglePlayback() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        controller.blocksLoadUntilCancelled = true
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        let toggle = Task { await vm.togglePlayback() }
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(vm.isLoadingSoundfonts)
        #expect(!vm.isPlaying)
        #expect(controller.loadCount == 0)

        vm.cancelLoadingSoundfonts()
        _ = await toggle.value
        #expect(!vm.isLoadingSoundfonts)
        #expect(!vm.isPlaying)
        #expect(controller.playCount == 0)
    }

    @Test func togglePlaybackIsNoOpWhenScoreNotLoaded() async {
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
        // No `await vm.load()`.
        await vm.togglePlayback()
        #expect(controller.loadCount == 0)
        #expect(controller.playCount == 0)
        #expect(!vm.isPlaying)
    }

    @Test func setVolumeForwardsToControllerByFlatStaffIndex() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()]),
                Part(id: "P1", trackName: "Pno", instrument: Instrument(id: "p"), staves: [Staff(), Staff()]),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        // Piano's lower staff is at (partIndex: 1, staffIndexInPart: 1)
        // → flat staff index 2 (Vn=0, Pno-top=1, Pno-bottom=2).
        let pianoBottom = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        vm.setVolume(0.3, for: pianoBottom)
        await Task.yield()
        await Task.yield()
        #expect(controller.staffVolumes[2] == 0.3)
    }
}
