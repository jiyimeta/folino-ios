import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderViewModelSoundfontSwapTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    private static func makeScore() -> Score {
        Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:],
        )
    }

    private static func makeGateway(score: Score) -> FakeScoreFileGateway {
        FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "Test", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            ),
        )))
    }

    /// Park the main actor briefly so `Observations`-backed tasks scheduled by mutations get a chance to run before the
    /// next assertion. 50 ms is comfortably larger than the framework's coalescing window without slowing the suite
    /// noticeably; the assertion-then-yield pattern is repeated rather than gambled on a single wait.
    private func yieldForObservation() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func `download finishing while paused triggers immediate reload`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let provider = FakeMuseScoreGeneralProvider(downloadState: .idle)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: Self.makeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            museScoreGeneralProvider: provider,
        )
        await vm.load()
        await vm.prepareForPlayback()
        vm.startObservingCursor()
        vm.startObservingSoundfontDownload()

        provider.downloadState = .downloaded
        await yieldForObservation()

        #expect(controller.reloadSoundfontCount == 1)
    }

    @Test func `download finishing while playing defers reload until pause`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let provider = FakeMuseScoreGeneralProvider(downloadState: .idle)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: Self.makeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            museScoreGeneralProvider: provider,
        )
        await vm.load()
        vm.startObservingCursor()
        vm.startObservingSoundfontDownload()
        await vm.togglePlayback()
        #expect(vm.isPlaying)

        provider.downloadState = .downloaded
        await yieldForObservation()
        // No reload yet — user is still playing and we never cut active audio.
        #expect(controller.reloadSoundfontCount == 0)

        // Engine pauses (user tap, lock-screen control, audio interruption, ...): the observer should drain the pending
        // swap and call `reloadSoundfont` on this transition.
        controller.emitIsPlaying(false)
        await yieldForObservation()

        #expect(controller.reloadSoundfontCount == 1)
    }

    @Test func `already-downloaded at Reader open never calls reload`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let provider = FakeMuseScoreGeneralProvider(downloadState: .downloaded)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: Self.makeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            museScoreGeneralProvider: provider,
        )
        await vm.load()
        await vm.prepareForPlayback()
        vm.startObservingCursor()
        vm.startObservingSoundfontDownload()
        await yieldForObservation()

        // The natural `controller.load(...)` already picked up the high-quality SF2 — re-prepare would be wasted work.
        #expect(controller.reloadSoundfontCount == 0)
    }

    @Test func `download finishing before engine load skips swap`() async {
        // Edge case: user opens Reader, download completes while the engine is still being prepared (or before play was
        // ever tapped). `controller.load(...)` will consume the new resolver URL when it eventually runs, so we mustn't
        // queue a redundant `reloadSoundfont` against an engine that has nothing loaded.
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let provider = FakeMuseScoreGeneralProvider(downloadState: .idle)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: Self.makeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            museScoreGeneralProvider: provider,
        )
        await vm.load()
        vm.startObservingCursor()
        vm.startObservingSoundfontDownload()
        // Note: NOT calling prepareForPlayback / togglePlayback.

        provider.downloadState = .downloaded
        await yieldForObservation()

        #expect(controller.reloadSoundfontCount == 0)
    }
}
