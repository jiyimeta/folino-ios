import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

/// The Reader half of the part-index migration: the Editor's save rewrites the persisted row, and the Reader has to
/// drop the copy it is still holding in memory and re-read. `ReaderViewModel.reloadPreferencesAfterPartRemap` is that
/// path; these cover its two moving parts at the store, which is where they are reachable without standing up a whole
/// Reader session.
@MainActor
struct ReaderPreferencesStorePartRemapTests {
    private let itemID = ScoreItemID(rawValue: UUID())
    private let pianoLower = StaffAddress(partIndex: 2, staffIndexInPart: 1)

    private func makeStore(_ repo: FakeScoreLibraryRepository) -> ReaderPreferencesStore {
        ReaderPreferencesStore(scoreItemID: itemID, repository: repo)
    }

    @Test func `a row migrated under the store is picked up by the reload`() async throws {
        let repo = FakeScoreLibraryRepository()
        let store = makeStore(repo)
        await store.loadOrSeed(authoredHiddenStaves: [])
        await store.mutate { $0.hiddenStaves = [pianoLower] }
        #expect(store.preferences.hiddenStaves == [pianoLower])

        // What the Editor's save does while this store holds the pre-migration copy: part 0 removed, so the piano
        // that was part 2 is now part 1.
        let stored = try #require(repo.storedReaderPreferences[itemID])
        repo.storedReaderPreferences[itemID] = stored.remappingParts([0: nil, 1: 0, 2: 1])

        await store.flushPendingWrites()
        let reloaded = await store.loadOrSeed(authoredHiddenStaves: [])

        let expected: Set<StaffAddress> = [StaffAddress(partIndex: 1, staffIndexInPart: 1)]
        #expect(reloaded.hiddenStaves == expected)
        #expect(store.preferences.hiddenStaves == expected)
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
}
