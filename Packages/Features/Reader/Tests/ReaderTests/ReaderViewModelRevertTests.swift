import Domain
import Foundation
@testable import Reader
import Testing

@MainActor
@Suite("ReaderViewModel revert to original")
struct ReaderViewModelRevertTests {
    private func makeVM(controller: FakePlaybackController, originalStore: FakeScoreOriginalStore) -> ReaderViewModel {
        ReaderViewModel(
            scoreItem: PreviewFakeRepository.sampleItem,
            repository: FakeScoreLibraryRepository(),
            originalStore: originalStore,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: FileManager.default.temporaryDirectory,
            playbackController: controller,
        )
    }

    /// The bug this guards (Important 3): a sheet-driven revert swapped the file under a live engine with no
    /// `releaseEngine()` call — the exact render-thread-crash shape `advance(to:)` and `adoptEditedScore` both
    /// guard against, and the Editor's own revert path guards against explicitly. Unlike `adoptEditedScore` (which
    /// swaps the in-memory score directly, then explicitly re-`prepareForPlayback()`), `revertToOriginal` reloads
    /// via the normal `load()` path — which parses the file but does not itself touch the playback controller, so
    /// `loadCount` staying at 1 here is correct and not what this test is about.
    @Test
    func `revertToOriginal stops playback before reloading`() async {
        let controller = FakePlaybackController()
        let store = FakeScoreOriginalStore()
        let vm = makeVM(controller: controller, originalStore: store)
        await vm.load()
        await vm.playbackSession.prepareForPlayback()
        #expect(controller.loadCount == 1)
        #expect(controller.releaseEngineCount == 0)

        await vm.revertToOriginal(vm.scoreItem, restoringScoreInfo: false)

        #expect(controller.releaseEngineCount == 1)
        // `load()` ran to completion (rather than exiting early some other way) — the reload half of the fix.
        #expect(vm.loadState.score != nil)
    }
}
