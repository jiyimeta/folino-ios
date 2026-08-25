import Domain
@testable import Editor
import Foundation
import Testing

/// Edit, save, then reopen the score the way a relaunch does — from the persisted row, in a brand-new view model.
///
/// This is the seam the strip's revert offer actually depends on and no other test covers: the capture happens
/// inside a save, and every existing test asserts it against the SAME view model that performed the save, where
/// `hasCapturedOriginal` is set in memory whether or not the row that reaches disk carries it.
@MainActor
@Suite("Original survives into the next session")
struct EditorOriginalRoundTripTests {
    @Test
    func `a score edited and saved offers revert when reopened from the stored row`() async throws {
        let repository = FakeScoreLibraryRepository()
        let store = FakeScoreOriginalStore()
        let item = EditorFixtures.sampleItem()
        repository.scoreItems = [item]

        let firstSession = EditorViewModel(
            scoreItem: item,
            scoresDirectory: FileManager.default.temporaryDirectory,
            gateway: FakeScoreFileGateway(),
            repository: repository,
            originalStore: store,
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
        firstSession.beginSession(score: EditorFixtures.fourQuarterRests())
        firstSession.previewSeedSessionEdit()
        firstSession.markDirtyForTesting()
        await firstSession.flushPendingSave()

        // What the library would hand the next launch.
        let storedItem = try #require(repository.scoreItems.first)
        #expect(storedItem.canRevertToOriginal, "the saved row must carry the captured original")

        let secondSession = EditorViewModel(
            scoreItem: storedItem,
            scoresDirectory: FileManager.default.temporaryDirectory,
            gateway: FakeScoreFileGateway(),
            repository: repository,
            originalStore: store,
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
        secondSession.beginSession(score: EditorFixtures.fourQuarterRests())
        #expect(secondSession.sessionEndMode == .revert)
    }

    /// The failure this was reported as: edit a note, kill the app, reopen, enter editing — and the strip offers a
    /// plain checkmark for a score that is no longer what was imported.
    ///
    /// A capture is copy-the-sidecar, write-the-score, update-the-row. The kill landed between the last two: the
    /// note survived (so the write finished, so the copy before it did too) while the row lost its original. The
    /// sidecar is on disk the whole time; nothing was looking for it.
    @Test
    func `a session whose row lost its original adopts the sidecar left on disk`() async {
        let repository = FakeScoreLibraryRepository()
        let store = FakeScoreOriginalStore()
        let item = EditorFixtures.sampleItem()
        repository.scoreItems = [item]
        // What survived the kill: the file is there, the row says there is no original.
        store.orphanedOriginalFileNames.insert(item.originalSidecarFileName)

        let viewModel = EditorViewModel(
            scoreItem: item,
            scoresDirectory: FileManager.default.temporaryDirectory,
            gateway: FakeScoreFileGateway(),
            repository: repository,
            originalStore: store,
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
        #expect(viewModel.sessionEndMode == .commitUnchanged, "before reconciling, the row is all it has to go on")

        viewModel.beginSession(score: EditorFixtures.fourQuarterRests())
        await viewModel.reconcileCapturedOriginal()

        #expect(viewModel.sessionEndMode == .revert)
        // And the row is repaired, so the next launch doesn't have to work it out again.
        #expect(repository.savedScoreItems.last?.canRevertToOriginal == true)
    }
}
