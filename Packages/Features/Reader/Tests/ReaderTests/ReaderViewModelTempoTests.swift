import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@Suite @MainActor
struct ReaderViewModelTempoTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    private static func makeVM(
        controller: FakePlaybackController = FakePlaybackController(),
        repo: FakeScoreLibraryRepository = FakeScoreLibraryRepository()
    ) -> (ReaderViewModel, FakePlaybackController, FakeScoreLibraryRepository) {
        let item = Self.makeItem()
        repo.scoreItems = [item]
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        return (vm, controller, repo)
    }

    @Test func effectiveTempoMultiplierDefaultsToOne() {
        let (vm, _, _) = Self.makeVM()
        #expect(vm.effectiveTempoMultiplier == 1.0)
    }

    @Test func setTempoMultiplierForwardsToControllerWithoutPersisting() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()
        let savedBefore = repo.savedReaderPreferences.count

        vm.setTempoMultiplier(0.75)

        // setTempoMultiplier kicks off an unstructured Task that awaits
        // the controller call. Yield once so the Task lands before
        // assertions read the call array.
        await Task.yield()

        #expect(controller.tempoMultiplierCalls == [0.75])
        #expect(repo.savedReaderPreferences.count == savedBefore)
        #expect(vm.effectiveTempoMultiplier == 1.0) // not yet committed
    }

    @Test func commitTempoMultiplierPersistsAndForwards() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()

        await vm.commitTempoMultiplier(0.75)

        #expect(controller.tempoMultiplierCalls.last == 0.75)
        #expect(repo.savedReaderPreferences.last?.tempoMultiplier == 0.75)
        #expect(vm.effectiveTempoMultiplier == 0.75)
    }

    @Test func commitTempoMultiplierNormalizesOneToNil() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()

        await vm.commitTempoMultiplier(1.0)

        #expect(repo.savedReaderPreferences.last?.tempoMultiplier == nil)
        #expect(controller.tempoMultiplierCalls.last == 1.0)
        #expect(vm.effectiveTempoMultiplier == 1.0)
    }

    @Test func commitTempoMultiplierClampsOutOfRangeValues() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()

        await vm.commitTempoMultiplier(3.0)

        #expect(repo.savedReaderPreferences.last?.tempoMultiplier == 2.0)
        #expect(vm.effectiveTempoMultiplier == 2.0)
        #expect(controller.tempoMultiplierCalls.last == 2.0)
    }

    @Test func resetTempoMultiplierClearsOverrideAndForwardsOne() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()
        await vm.commitTempoMultiplier(1.5)

        await vm.resetTempoMultiplier()

        #expect(repo.savedReaderPreferences.last?.tempoMultiplier == nil)
        #expect(controller.tempoMultiplierCalls.last == 1.0)
        #expect(vm.effectiveTempoMultiplier == 1.0)
    }

    @Test func persistedOverrideIsSeededIntoEngineOnPlaybackPrep() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        // Pre-seed the persisted preferences with a non-default override.
        let stored = ReaderPreferences(
            scoreItemID: item.id,
            staffSize: 14,
            hiddenStaves: [],
            tempoMultiplier: 0.75
        )
        repo.storedReaderPreferences[item.id] = stored
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )

        await vm.load()
        await vm.prepareForPlayback()

        #expect(controller.lastLoadedPreferences?.tempoMultiplier == 0.75)
    }

    @Test func commitTempoMultiplierNormalizesNear1ToNil() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()

        // Slider value that visually maps to 100% display
        // (Int((value * 100).rounded()) == 100) but is not exactly 1.0.
        await vm.commitTempoMultiplier(0.9999)

        #expect(repo.savedReaderPreferences.last?.tempoMultiplier == nil)
        #expect(controller.tempoMultiplierCalls.last == 1.0)
        #expect(vm.effectiveTempoMultiplier == 1.0)
    }

    @Test func setMetronomeEnabledForwardsWithoutPersisting() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()
        let savedBefore = repo.savedReaderPreferences.count

        await vm.setMetronomeEnabled(true)
        await vm.setMetronomeEnabled(false)

        #expect(controller.metronomeEnabledCalls == [true, false])
        #expect(repo.savedReaderPreferences.count == savedBefore)
    }
}
