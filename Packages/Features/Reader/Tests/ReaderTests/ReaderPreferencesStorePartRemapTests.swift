import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

/// The Reader half of the part-index migration. The Editor's save rewrites the persisted row; the Reader has to stop
/// writing that row while the two disagree about what a part index means, then drop the copy it is holding and
/// re-read. `ReaderViewModel.reloadPreferencesAfterPartRemap` is that path; these cover its moving parts at the
/// store, which is where they are reachable without standing up a whole Reader session.
@MainActor
struct ReaderPreferencesStorePartRemapTests {
    private let itemID = ScoreItemID(rawValue: UUID())
    private let pianoLower = StaffAddress(partIndex: 2, staffIndexInPart: 1)
    /// Where the piano's lower staff lands once the part above it is gone.
    private let pianoLowerAfterRemoval = StaffAddress(partIndex: 1, staffIndexInPart: 1)

    private func makeStore(_ repo: FakeScoreLibraryRepository) -> ReaderPreferencesStore {
        ReaderPreferencesStore(scoreItemID: itemID, repository: repo)
    }

    /// Stands in for `LayoutSettingsModel`: the in-memory copy the Reader holds and writes back from. A class so a
    /// deferred mutation closure reads whatever it holds AT THE MOMENT IT RUNS, exactly as the real one does.
    private final class HiddenStavesModel {
        var hiddenStaves: Set<StaffAddress> = []
    }

    /// What the Editor's save does to the row: part 0 removed, so the piano that was part 2 is now part 1.
    private func migrateRowExternally(_ repo: FakeScoreLibraryRepository) throws {
        let stored = try #require(repo.storedReaderPreferences[itemID])
        repo.storedReaderPreferences[itemID] = stored.remappingParts([0: nil, 1: 0, 2: 1])
    }

    // MARK: - Reload

    @Test func `a row migrated under the store is picked up by the reload`() async throws {
        let repo = FakeScoreLibraryRepository()
        let store = makeStore(repo)
        await store.loadOrSeed(authoredHiddenStaves: [])
        await store.mutate { $0.hiddenStaves = [pianoLower] }
        #expect(store.preferences.hiddenStaves == [pianoLower])

        try migrateRowExternally(repo)

        await store.flushPendingWrites()
        let reloaded = await store.loadOrSeed(authoredHiddenStaves: [])

        #expect(reloaded?.hiddenStaves == [pianoLowerAfterRemoval])
        #expect(store.preferences.hiddenStaves == [pianoLowerAfterRemoval])
    }

    /// Without the flush, a write still in the air would land on top of the row the reload is about to read — and the
    /// migration would be silently undone. Nothing pending is the common case and must not block.
    @Test func `flushing with nothing pending returns immediately`() async {
        let store = makeStore(FakeScoreLibraryRepository())
        await store.flushPendingWrites()
    }

    @Test func `flushing joins a write started elsewhere`() async {
        let repo = FakeScoreLibraryRepository()
        let store = makeStore(repo)
        await store.loadOrSeed(authoredHiddenStaves: [])
        // `mutate` awaits its own write, so the handle it leaves behind is only interesting to a DIFFERENT caller —
        // hence driving it from a task and joining from here.
        let write = Task { await store.mutate { $0.hiddenStaves = [pianoLower] } }
        await write.value

        await store.flushPendingWrites()

        #expect(repo.storedReaderPreferences[itemID]?.hiddenStaves == [pianoLower])
    }

    // MARK: - The hold (review Critical 1)

    /// Scenario (a): the user deletes a part and, inside the window before the migration reads the row, toggles a
    /// staff. That toggle is stamped in the POST-edit numbering — persisting it would hand the migration a row it
    /// then remaps a SECOND time, landing the setting on a different part. Held instead, and the row ends fully in
    /// the post-edit numbering with nothing double-remapped.
    @Test func `a post-edit-numbered write inside the window is never double-remapped`() async throws {
        let repo = FakeScoreLibraryRepository()
        let store = makeStore(repo)
        let model = HiddenStavesModel()
        await store.loadOrSeed(authoredHiddenStaves: [])
        model.hiddenStaves = [pianoLower]
        await store.mutate { $0.hiddenStaves = model.hiddenStaves }

        // The part op lands: the hold goes up, and the user toggles a staff in the sheet straight away. The toggle
        // is written against the parts as they are NOW — the piano has moved to index 1.
        var isPending = true
        store.isMigrationPending = { isPending }
        model.hiddenStaves = [pianoLowerAfterRemoval, StaffAddress(partIndex: 0, staffIndexInPart: 0)]
        await store.mutate { $0.hiddenStaves = model.hiddenStaves }

        // Held: the row the migration is about to read still says what it said.
        #expect(repo.storedReaderPreferences[itemID]?.hiddenStaves == [pianoLower])

        // The Editor migrates and the hold lifts; the reload re-seeds the model from the migrated row, then lets the
        // held write go.
        try migrateRowExternally(repo)
        isPending = false
        await store.flushPendingWrites()
        let reloaded = try #require(await store.loadOrSeed(authoredHiddenStaves: []))
        model.hiddenStaves = reloaded.hiddenStaves
        await store.applyDeferredMutations()

        let final = try #require(repo.storedReaderPreferences[itemID])
        #expect(final.hiddenStaves == [pianoLowerAfterRemoval])
        // Double-remapping would have moved the piano's staff a second time, to part 0.
        #expect(!final.hiddenStaves.contains { $0.partIndex == 0 })
    }

    /// Scenario (b): a write stamped in the OLD numbering that lands AFTER the migration would clobber the migrated
    /// row — and the Editor has consumed the map by then, so nothing ever retries and the row is wrong for good.
    /// Held, the migrated row survives, and the held write re-applies from the reloaded state.
    @Test func `a stale-numbered write held through the window cannot clobber the migrated row`() async throws {
        let repo = FakeScoreLibraryRepository()
        let store = makeStore(repo)
        let model = HiddenStavesModel()
        await store.loadOrSeed(authoredHiddenStaves: [])
        model.hiddenStaves = [pianoLower]
        await store.mutate { $0.hiddenStaves = model.hiddenStaves }

        var isPending = true
        store.isMigrationPending = { isPending }
        // A sub-model still holding the PRE-edit numbering asks to persist itself.
        await store.mutate { $0.hiddenStaves = model.hiddenStaves }

        try migrateRowExternally(repo)
        #expect(repo.storedReaderPreferences[itemID]?.hiddenStaves == [pianoLowerAfterRemoval])

        isPending = false
        await store.flushPendingWrites()
        let reloaded = try #require(await store.loadOrSeed(authoredHiddenStaves: []))
        model.hiddenStaves = reloaded.hiddenStaves
        await store.applyDeferredMutations()

        // The migrated row survived, and the held write re-applied from the reloaded state rather than the stale one.
        #expect(repo.storedReaderPreferences[itemID]?.hiddenStaves == [pianoLowerAfterRemoval])
        #expect(store.preferences.hiddenStaves == [pianoLowerAfterRemoval])
    }

    @Test func `a held write is queued, not dropped`() async {
        let repo = FakeScoreLibraryRepository()
        let store = makeStore(repo)
        await store.loadOrSeed(authoredHiddenStaves: [])
        var isPending = true
        store.isMigrationPending = { isPending }

        await store.mutate { $0.masterVolume = 2 }
        // Nothing written, and the in-memory value is untouched too — it must never hold a value the row will not
        // be given.
        #expect(repo.savedReaderPreferences.isEmpty)
        #expect(store.preferences.masterVolume == nil)

        isPending = false
        await store.applyDeferredMutations()

        #expect(store.preferences.masterVolume == 2)
        #expect(repo.storedReaderPreferences[itemID]?.masterVolume == 2)
    }

    /// The release is on the far side of the re-read, so a write arriving between the reload starting and the hold
    /// coming down is still inside the window — the sub-models have not been re-seeded yet, so it would carry
    /// pre-migration addresses. It must be queued like any other (round-2 Important A).
    @Test func `a write arriving mid-reload is still held`() async throws {
        let repo = FakeScoreLibraryRepository()
        let store = makeStore(repo)
        let model = HiddenStavesModel()
        await store.loadOrSeed(authoredHiddenStaves: [])
        model.hiddenStaves = [pianoLower]
        await store.mutate { $0.hiddenStaves = model.hiddenStaves }

        var isPending = true
        store.isMigrationPending = { isPending }
        try migrateRowExternally(repo)

        // The reload's own steps, in order. The hold is still up through both of them.
        await store.flushPendingWrites()
        let reloaded = try #require(await store.loadOrSeed(authoredHiddenStaves: []))
        // …and a write lands right here, after the re-read but before the release.
        await store.mutate { $0.masterVolume = 3 }
        #expect(repo.storedReaderPreferences[itemID]?.masterVolume == nil)

        // Only now does the hold come down, and only then does the queued write go.
        model.hiddenStaves = reloaded.hiddenStaves
        isPending = false
        await store.applyDeferredMutations()

        #expect(repo.storedReaderPreferences[itemID]?.masterVolume == 3)
        #expect(repo.storedReaderPreferences[itemID]?.hiddenStaves == [pianoLowerAfterRemoval])
    }

    /// `loadOrSeed`'s authored-visibility refresh reaches `persist` without going through `mutate`, and it rewrites
    /// `hiddenStaves` / `authoredHiddenStaves` — part-indexed state like any other. It has to respect the hold too
    /// (round-2 minor). Skipped rather than queued: the refresh is re-derived from the score every time, so the next
    /// open re-attempts it.
    @Test func `the authored-visibility refresh does not escape the hold`() async {
        let repo = FakeScoreLibraryRepository()
        let store = makeStore(repo)
        // A stored row whose recorded provenance disagrees with the score, so the reconcile wants to write.
        repo.storedReaderPreferences[itemID] = ReaderPreferences(
            scoreItemID: itemID, hiddenStaves: [], hasSeededAuthoredVisibility: true,
        )
        store.isMigrationPending = { true }

        await store.loadOrSeed(authoredHiddenStaves: [pianoLowerAfterRemoval])

        #expect(repo.savedReaderPreferences.isEmpty)
    }

    /// The no-score bail has no migrated row to re-run the queue against, so it drops it — and must, or the hold
    /// would be released with writes still queued behind it.
    @Test func `discarding the queue leaves nothing to replay`() async {
        let repo = FakeScoreLibraryRepository()
        let store = makeStore(repo)
        await store.loadOrSeed(authoredHiddenStaves: [])
        store.isMigrationPending = { true }
        await store.mutate { $0.masterVolume = 2 }

        store.discardDeferredMutations()
        store.isMigrationPending = { false }
        await store.applyDeferredMutations()

        #expect(repo.savedReaderPreferences.isEmpty)
        #expect(store.preferences.masterVolume == nil)
    }

    // MARK: - A failed load is not an empty one (review Minor 3)

    @Test func `a throwing load reports failure instead of minting a fresh row`() async {
        let repo = FakeScoreLibraryRepository()
        let store = makeStore(repo)
        repo.storedReaderPreferences[itemID] = ReaderPreferences(
            scoreItemID: itemID, hiddenStaves: [pianoLowerAfterRemoval],
        )
        await store.loadOrSeed(authoredHiddenStaves: [])

        repo.loadError = DomainError.persistenceFailed(reason: "boom")
        let result = await store.loadOrSeed(authoredHiddenStaves: [])

        #expect(result == nil)
        // The in-memory copy is left exactly as it was — a failed read must not wipe a just-migrated row.
        #expect(store.preferences.hiddenStaves == [pianoLowerAfterRemoval])
        #expect(repo.savedReaderPreferences.isEmpty)
    }

    @Test func `no row is still a seed, not a failure`() async {
        let repo = FakeScoreLibraryRepository()
        let store = makeStore(repo)
        let result = await store.loadOrSeed(authoredHiddenStaves: [pianoLower])
        #expect(result?.hiddenStaves == [pianoLower])
    }
}
