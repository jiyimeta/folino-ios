import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

/// `ReaderViewModel.reloadPreferencesAfterPartRemap` — the far end of the part-index migration, where the Reader
/// drops the copy it is holding and re-reads the row the Editor has just rewritten.
///
/// What these pin down is the failure path. The happy path replays the writes held during the migration against the
/// freshly re-seeded sub-models; a re-read that FAILED re-seeds nothing, so replaying then would persist the
/// pre-migration addresses those models are still holding, straight over the migrated row — and the Editor has
/// consumed the map by then, so nothing would ever put it right.
@MainActor
struct ReaderViewModelPartRemapReloadTests {
    private let pianoLower = StaffAddress(partIndex: 2, staffIndexInPart: 1)
    private let pianoLowerAfterRemoval = StaffAddress(partIndex: 1, staffIndexInPart: 1)

    private func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    private func makeVM(_ repo: FakeScoreLibraryRepository, item: ScoreItem) -> ReaderViewModel {
        repo.scoreItems = [item]
        return ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: FakePlaybackController(),
        )
    }

    /// Stands the view model up mid-session: a row in the PRE-migration numbering, distributed into the sub-models,
    /// with the hold up and one write queued behind it — then the Editor migrates the row underneath.
    private func makePendingMigration(
        _ repo: FakeScoreLibraryRepository,
        item: ScoreItem,
        isPending: @escaping @MainActor () -> Bool,
    ) async -> ReaderViewModel {
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, hiddenStaves: [pianoLower],
        )
        let vm = makeVM(repo, item: item)
        await vm.loadOrSeedPreferences()
        vm.setPreferenceMigrationPendingProvider(isPending)
        return vm
    }

    /// The Editor's save, as seen from here: the row is rewritten while this process holds the old copy.
    private func migrateRowExternally(_ repo: FakeScoreLibraryRepository, item: ScoreItem) throws {
        let stored = try #require(repo.storedReaderPreferences[item.id])
        repo.storedReaderPreferences[item.id] = stored.remappingParts([0: nil, 1: 0, 2: 1])
    }

    @Test func `a successful re-read re-seeds and lets the held writes go`() async throws {
        let repo = FakeScoreLibraryRepository()
        let item = makeItem()
        var isPending = true
        let vm = await makePendingMigration(repo, item: item) { isPending }
        #expect(vm.layoutModel.hiddenStaves == [pianoLower])

        await vm.mutatePreferences { $0.masterVolume = 2 }
        #expect(repo.storedReaderPreferences[item.id]?.masterVolume == nil)
        try migrateRowExternally(repo, item: item)

        await vm.reloadPreferencesAfterPartRemap(authoredHiddenStaves: []) {
            isPending = false
            return true
        }

        // Re-seeded from the migrated row, and the queued write landed on top of it.
        #expect(vm.layoutModel.hiddenStaves == [pianoLowerAfterRemoval])
        #expect(repo.storedReaderPreferences[item.id]?.hiddenStaves == [pianoLowerAfterRemoval])
        #expect(repo.storedReaderPreferences[item.id]?.masterVolume == 2)
    }

    /// The one this exists for. A throwing load re-seeds nothing, so the queue must be dropped rather than replayed
    /// — and the hold must still come down, or it strands.
    @Test func `a failed re-read lifts the hold but discards the held writes`() async throws {
        let repo = FakeScoreLibraryRepository()
        let item = makeItem()
        var isPending = true
        let vm = await makePendingMigration(repo, item: item) { isPending }

        await vm.mutatePreferences { $0.masterVolume = 2 }
        try migrateRowExternally(repo, item: item)
        let migrated = try #require(repo.storedReaderPreferences[item.id])
        let savedBefore = repo.savedReaderPreferences.count

        repo.loadError = DomainError.persistenceFailed(reason: "boom")
        var didLift = false
        await vm.reloadPreferencesAfterPartRemap(authoredHiddenStaves: []) {
            isPending = false
            didLift = true
            return true
        }

        // The hold came down — leaving it up is the stranded-hold failure mode.
        #expect(didLift)
        // Nothing was written: the queue was discarded, not replayed.
        #expect(repo.savedReaderPreferences.count == savedBefore)
        #expect(repo.storedReaderPreferences[item.id] == migrated)
        // And the sub-models were not re-seeded — they still hold what they held, rather than defaults.
        #expect(vm.layoutModel.hiddenStaves == [pianoLower])

        // The queue really is empty: a later release has nothing left to replay over the migrated row.
        repo.loadError = nil
        await vm.applyDeferredPreferenceWrites()
        #expect(repo.savedReaderPreferences.count == savedBefore)
        #expect(repo.storedReaderPreferences[item.id] == migrated)
    }

    /// A release that does NOT come down (a second part edit is still unsettled) leaves the queue alone either way
    /// — it belongs to that edit's own release.
    @Test func `a hold that stays up keeps the queue`() async throws {
        let repo = FakeScoreLibraryRepository()
        let item = makeItem()
        let vm = await makePendingMigration(repo, item: item) { true }

        await vm.mutatePreferences { $0.masterVolume = 2 }
        try migrateRowExternally(repo, item: item)

        await vm.reloadPreferencesAfterPartRemap(authoredHiddenStaves: []) { false }

        #expect(repo.storedReaderPreferences[item.id]?.masterVolume == nil)
        // Still queued, so the later release can land it.
        vm.setPreferenceMigrationPendingProvider { false }
        await vm.applyDeferredPreferenceWrites()
        #expect(repo.storedReaderPreferences[item.id]?.masterVolume == 2)
    }
}
