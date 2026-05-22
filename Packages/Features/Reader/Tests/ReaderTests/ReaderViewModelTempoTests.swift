import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderViewModelTempoTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    private static func makeVM(
        controller: FakePlaybackController = FakePlaybackController(),
        repo: FakeScoreLibraryRepository = FakeScoreLibraryRepository(),
    ) -> (ReaderViewModel, FakePlaybackController, FakeScoreLibraryRepository) {
        let item = Self.makeItem()
        repo.scoreItems = [item]
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        return (vm, controller, repo)
    }

    @Test func `effective tempo multiplier defaults to one`() {
        let (vm, _, _) = Self.makeVM()
        #expect(vm.tempoModel.effectiveMultiplier == 1.0)
    }

    @Test func `set tempo multiplier forwards to controller without persisting`() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()
        let savedBefore = repo.savedReaderPreferences.count

        vm.tempoModel.setMultiplier(0.75)

        // setTempoMultiplier kicks off an unstructured Task that awaits the controller call. Yield once so the Task
        // lands before assertions read the call array.
        await Task.yield()

        #expect(controller.tempoMultiplierCalls == [0.75])
        #expect(repo.savedReaderPreferences.count == savedBefore)
        #expect(vm.tempoModel.effectiveMultiplier == 1.0) // not yet committed
    }

    @Test func `commit tempo multiplier persists and forwards`() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()

        await vm.tempoModel.commitMultiplier(0.75)

        #expect(controller.tempoMultiplierCalls.last == 0.75)
        #expect(repo.savedReaderPreferences.last?.tempoMultiplier == 0.75)
        #expect(vm.tempoModel.effectiveMultiplier == 0.75)
    }

    @Test func `commit tempo multiplier normalizes one to nil`() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()

        await vm.tempoModel.commitMultiplier(1.0)

        #expect(repo.savedReaderPreferences.last?.tempoMultiplier == nil)
        #expect(controller.tempoMultiplierCalls.last == 1.0)
        #expect(vm.tempoModel.effectiveMultiplier == 1.0)
    }

    @Test func `commit tempo multiplier clamps out of range values`() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()

        await vm.tempoModel.commitMultiplier(3.0)

        #expect(repo.savedReaderPreferences.last?.tempoMultiplier == 2.0)
        #expect(vm.tempoModel.effectiveMultiplier == 2.0)
        #expect(controller.tempoMultiplierCalls.last == 2.0)
    }

    @Test func `reset tempo multiplier clears override and forwards one`() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()
        await vm.tempoModel.commitMultiplier(1.5)

        await vm.tempoModel.resetMultiplier()

        #expect(repo.savedReaderPreferences.last?.tempoMultiplier == nil)
        #expect(controller.tempoMultiplierCalls.last == 1.0)
        #expect(vm.tempoModel.effectiveMultiplier == 1.0)
    }

    @Test func `persisted override is seeded into engine on playback prep`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        // Pre-seed the persisted preferences with a non-default override.
        let stored = ReaderPreferences(
            scoreItemID: item.id,
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 0.75,
        )
        repo.storedReaderPreferences[item.id] = stored
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )

        await vm.load()
        await vm.playbackSession.prepareForPlayback()

        #expect(controller.lastLoadedPreferences?.tempoMultiplier == 0.75)
    }

    @Test func `commit tempo multiplier normalizes near 1 to nil`() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()

        // Slider value that visually maps to 100% display (Int((value * 100).rounded()) == 100) but is not exactly 1.0.
        await vm.tempoModel.commitMultiplier(0.9999)

        #expect(repo.savedReaderPreferences.last?.tempoMultiplier == nil)
        #expect(controller.tempoMultiplierCalls.last == 1.0)
        #expect(vm.tempoModel.effectiveMultiplier == 1.0)
    }

    @Test func `set metronome enabled forwards without persisting`() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()
        let savedBefore = repo.savedReaderPreferences.count

        await vm.tempoModel.setMetronomeEnabled(true)
        await vm.tempoModel.setMetronomeEnabled(false)

        #expect(controller.metronomeEnabledCalls == [true, false])
        #expect(repo.savedReaderPreferences.count == savedBefore)
    }
}
