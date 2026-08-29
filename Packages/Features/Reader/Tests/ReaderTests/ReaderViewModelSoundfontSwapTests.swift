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

    /// Park the main actor so `Observations`-backed tasks scheduled by mutations get a chance to run before the next
    /// assertion. Polls with a 10 ms tick so the check fires as soon as the condition settles rather than waiting out
    /// a fixed sleep.
    ///
    /// The budget is a hang guard, not an expectation: this suite shares the main actor with every other
    /// `@MainActor` suite in the bundle, and how long the swap waits for a turn is not ours to predict. It was 500 ms
    /// and flaked — instrumented over five full-bundle runs the condition always did settle, but took up to 1.61 s
    /// under load, so the budget was simply too close to the real distribution. A large budget costs nothing on the
    /// happy path, which is the common one (typically under 50 ms).
    private func yieldForObservation(until condition: @MainActor () -> Bool = { true }) async {
        let deadline = Date.now.addingTimeInterval(30)
        repeat {
            try? await Task.sleep(for: .milliseconds(10))
        } while !condition() && Date.now < deadline
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
        await vm.playbackSession.prepareForPlayback()
        vm.playbackSession.startObservingCursor()
        vm.playbackSession.startObservingSoundfontDownload()

        provider.downloadState = .downloaded
        await yieldForObservation(until: { controller.reloadSoundfontCount == 1 })

        #expect(controller.reloadSoundfontCount == 1)
    }

    /// The swap re-prepares the loaded score, so the mixer has to re-read the engine's strips afterwards. Anchoring
    /// the refresh to the load paths alone would leave the mixer describing the pre-swap engine for the rest of the
    /// session.
    @Test func `a soundfont swap refreshes the mixer's strips`() async {
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
        // Nothing to report at load time, so the mixer starts empty and only the swap can fill it.
        await vm.playbackSession.prepareForPlayback()
        vm.playbackSession.startObservingCursor()
        vm.playbackSession.startObservingSoundfontDownload()
        #expect(vm.mixerModel.strips.isEmpty)

        let strip = MixerStripID(partIndex: 0, instrumentOrdinal: 0)
        controller.strips = [
            MixerStrip(
                id: strip, partName: "Vn", instrumentName: "Vn",
                defaultVolume: 1, defaultProgram: 40, isDrums: false,
            ),
        ]
        provider.downloadState = .downloaded
        await yieldForObservation(until: { !vm.mixerModel.strips.isEmpty })

        #expect(controller.reloadSoundfontCount == 1)
        #expect(vm.mixerModel.strips.map(\.id) == [strip])
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
        vm.playbackSession.startObservingCursor()
        vm.playbackSession.startObservingSoundfontDownload()
        await vm.playbackSession.togglePlayback()
        #expect(vm.playbackSession.isPlaying)

        provider.downloadState = .downloaded
        await yieldForObservation()
        // No reload yet — user is still playing and we never cut active audio.
        #expect(controller.reloadSoundfontCount == 0)

        // Engine pauses (user tap, lock-screen control, audio interruption, ...): the observer should drain the pending
        // swap and call `reloadSoundfont` on this transition.
        controller.emitIsPlaying(false)
        await yieldForObservation(until: { controller.reloadSoundfontCount == 1 })

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
        await vm.playbackSession.prepareForPlayback()
        vm.playbackSession.startObservingCursor()
        vm.playbackSession.startObservingSoundfontDownload()
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
        vm.playbackSession.startObservingCursor()
        vm.playbackSession.startObservingSoundfontDownload()
        // Note: NOT calling prepareForPlayback / togglePlayback.

        provider.downloadState = .downloaded
        await yieldForObservation()

        #expect(controller.reloadSoundfontCount == 0)
    }
}
