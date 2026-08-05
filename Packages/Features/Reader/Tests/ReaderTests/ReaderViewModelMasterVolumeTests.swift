import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderViewModelMasterVolumeTests {
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

    @Test func `master volume defaults to unity`() {
        let (vm, _, _) = Self.makeVM()
        // Untouched — the slider reads unity without the score being marked as one the user set a volume on.
        #expect(vm.masterVolumeModel.value == nil)
        #expect(vm.masterVolumeModel.displayValue == 1.0)
    }

    @Test func `set master volume forwards to controller without persisting`() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()
        let savedBefore = repo.savedReaderPreferences.count

        vm.masterVolumeModel.setValue(2.0)

        // setValue kicks off an unstructured Task that awaits the controller call. Yield once so the Task lands before
        // assertions read the call array.
        await Task.yield()

        #expect(controller.masterVolumeCalls == [2.0])
        #expect(repo.savedReaderPreferences.count == savedBefore)
        #expect(vm.masterVolumeModel.value == nil) // not yet committed
        #expect(vm.masterVolumeModel.displayValue == 2.0) // transient drag value
    }

    @Test func `commit master volume persists and forwards`() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()

        await vm.masterVolumeModel.commitValue(2.5)

        #expect(controller.masterVolumeCalls.last == 2.5)
        #expect(repo.savedReaderPreferences.last?.masterVolume == 2.5)
        #expect(vm.masterVolumeModel.value == 2.5)
    }

    @Test func `commit master volume clamps out of range values`() async {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()

        await vm.masterVolumeModel.commitValue(5.0)

        #expect(repo.savedReaderPreferences.last?.masterVolume == 3.0)
        #expect(vm.masterVolumeModel.value == 3.0)
        #expect(controller.masterVolumeCalls.last == 3.0)
    }

    @Test func `reset master volume clears boost and forwards unity`() async throws {
        let (vm, controller, repo) = Self.makeVM()
        await vm.load()
        await vm.masterVolumeModel.commitValue(2.0)

        await vm.masterVolumeModel.resetValue()

        // Reset is the one affordance that writes "untouched" back — the persisted value goes to nil, not to an
        // explicit 1.0, so the score stops counting as one the user set a master volume on.
        let saved = try #require(repo.savedReaderPreferences.last)
        #expect(saved.masterVolume == nil)
        #expect(controller.masterVolumeCalls.last == 1.0)
        #expect(vm.masterVolumeModel.value == nil)
        #expect(vm.masterVolumeModel.displayValue == 1.0)
    }

    @Test func `committing exactly unity is kept as an explicit choice`() async throws {
        let (vm, _, repo) = Self.makeVM()
        await vm.load()

        await vm.masterVolumeModel.commitValue(ReaderPreferences.defaultMasterVolume)

        let saved = try #require(repo.savedReaderPreferences.last)
        #expect(saved.masterVolume == 1.0)
        #expect(vm.masterVolumeModel.value == 1.0)
    }

    @Test func `persisted master volume is seeded into engine on playback prep`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        // Pre-seed the persisted preferences with a non-default boost.
        let stored = ReaderPreferences(
            scoreItemID: item.id,
            staffSize: 14,
            hiddenStaves: [],
            masterVolume: 2.0,
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

        #expect(controller.lastLoadedPreferences?.masterVolume == 2.0)
        #expect(vm.masterVolumeModel.value == 2.0)
    }
}
