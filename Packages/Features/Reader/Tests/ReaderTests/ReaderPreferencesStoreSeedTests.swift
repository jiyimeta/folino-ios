import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

/// `ReaderPreferencesStore.loadOrSeed(authoredHiddenStaves:)` seeds a score's authored-hidden staves
/// (`<Part><show>0</show>`) as the initial `hiddenStaves`, back-fills pre-feature rows exactly once, and
/// never re-hides staves the user revealed.
@MainActor
struct ReaderPreferencesStoreSeedTests {
    private let itemID = ScoreItemID(rawValue: UUID())
    private let authored = StaffAddress(partIndex: 1, staffIndexInPart: 0)
    private let userHidden = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private func makeStore(_ repo: FakeScoreLibraryRepository) -> ReaderPreferencesStore {
        ReaderPreferencesStore(scoreItemID: itemID, repository: repo)
    }

    @Test func `seeds authored hidden when no row exists`() async {
        let repo = FakeScoreLibraryRepository()
        let result = await makeStore(repo).loadOrSeed(authoredHiddenStaves: [authored])
        #expect(result?.hiddenStaves == [authored])
        #expect(result?.hasSeededAuthoredVisibility == true)
        #expect(repo.savedReaderPreferences.count == 1)
    }

    /// §5: a first open that learns nothing — no stored row, and the score authors nothing hidden — writes no row at
    /// all. The store has to honor `reconcilingAuthoredHidden`'s persist flag; saving the resolved value
    /// unconditionally would make every score the user merely opened read as configured in the launch snapshot.
    @Test func `loadOrSeed with no row and no authored staves performs no save`() async {
        let repo = FakeScoreLibraryRepository()
        await makeStore(repo).loadOrSeed(authoredHiddenStaves: [])
        #expect(repo.savedReaderPreferences.isEmpty)
    }

    @Test func `backfills authored hidden into pre feature row`() async {
        let repo = FakeScoreLibraryRepository()
        repo.storedReaderPreferences[itemID] = ReaderPreferences(
            scoreItemID: itemID, staffSize: 14, hiddenStaves: [],
            hasSeededAuthoredVisibility: false,
        )
        let result = await makeStore(repo).loadOrSeed(authoredHiddenStaves: [authored])
        #expect(result?.hiddenStaves == [authored])
        #expect(result?.hasSeededAuthoredVisibility == true)
        #expect(repo.savedReaderPreferences.count == 1)
    }

    @Test func `backfill unions with user hidden staves`() async {
        let repo = FakeScoreLibraryRepository()
        repo.storedReaderPreferences[itemID] = ReaderPreferences(
            scoreItemID: itemID, staffSize: 14, hiddenStaves: [userHidden],
            hasSeededAuthoredVisibility: false,
        )
        let result = await makeStore(repo).loadOrSeed(authoredHiddenStaves: [authored])
        #expect(result?.hiddenStaves == [userHidden, authored])
    }

    /// `mutate` re-runs `ReaderPreferences.init` to re-apply clamping, so every field has to be forwarded. Provenance
    /// is the easiest one to drop: losing it would make the next open re-record it, and would make Task 9's analytics
    /// read every authored-hidden staff as one the user hid.
    @Test func `mutate preserves authored provenance and untouched fields`() async throws {
        let repo = FakeScoreLibraryRepository()
        let store = makeStore(repo)
        await store.loadOrSeed(authoredHiddenStaves: [authored])

        await store.mutate { $0.hiddenStaves.insert(userHidden) }

        let saved = try #require(repo.savedReaderPreferences.last)
        #expect(saved.authoredHiddenStaves == [authored])
        #expect(saved.hiddenStaves == [authored, userHidden])
        #expect(saved.staffSize == nil)
        #expect(saved.honorLayoutBreaks == nil)
        #expect(saved.masterVolume == nil)
        #expect(saved.transposeSemitones == nil)
    }

    @Test func `respects user reveal once seeded`() async throws {
        let repo = FakeScoreLibraryRepository()
        // Already seeded, and the user revealed everything (empty set). A reopen must NOT re-hide.
        repo.storedReaderPreferences[itemID] = ReaderPreferences(
            scoreItemID: itemID, staffSize: 14, hiddenStaves: [],
            hasSeededAuthoredVisibility: true,
        )
        let result = await makeStore(repo).loadOrSeed(authoredHiddenStaves: [authored])
        #expect(result?.hiddenStaves.isEmpty == true)
        // The row predates `authoredHiddenStaves`, so its recorded (empty) provenance differs from what the score
        // authors. The refresh rule writes the provenance back — and only the provenance: what the user revealed
        // stays revealed.
        let saved = try #require(repo.savedReaderPreferences.last)
        #expect(repo.savedReaderPreferences.count == 1)
        #expect(saved.hiddenStaves.isEmpty)
        #expect(saved.authoredHiddenStaves == [authored])
    }
}
