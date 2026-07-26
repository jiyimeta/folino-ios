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
        ReaderPreferencesStore(scoreItemID: itemID, defaultStaffSize: 14, repository: repo)
    }

    @Test func `seeds authored hidden when no row exists`() async {
        let repo = FakeScoreLibraryRepository()
        let result = await makeStore(repo).loadOrSeed(authoredHiddenStaves: [authored])
        #expect(result.hiddenStaves == [authored])
        #expect(result.hasSeededAuthoredVisibility)
        #expect(repo.savedReaderPreferences.count == 1)
    }

    @Test func `backfills authored hidden into pre feature row`() async {
        let repo = FakeScoreLibraryRepository()
        repo.storedReaderPreferences[itemID] = ReaderPreferences(
            scoreItemID: itemID, staffSize: 14, hiddenStaves: [],
            hasSeededAuthoredVisibility: false,
        )
        let result = await makeStore(repo).loadOrSeed(authoredHiddenStaves: [authored])
        #expect(result.hiddenStaves == [authored])
        #expect(result.hasSeededAuthoredVisibility)
        #expect(repo.savedReaderPreferences.count == 1)
    }

    @Test func `backfill unions with user hidden staves`() async {
        let repo = FakeScoreLibraryRepository()
        repo.storedReaderPreferences[itemID] = ReaderPreferences(
            scoreItemID: itemID, staffSize: 14, hiddenStaves: [userHidden],
            hasSeededAuthoredVisibility: false,
        )
        let result = await makeStore(repo).loadOrSeed(authoredHiddenStaves: [authored])
        #expect(result.hiddenStaves == [userHidden, authored])
    }

    @Test func `respects user reveal once seeded`() async {
        let repo = FakeScoreLibraryRepository()
        // Already seeded, and the user revealed everything (empty set). A reopen must NOT re-hide.
        repo.storedReaderPreferences[itemID] = ReaderPreferences(
            scoreItemID: itemID, staffSize: 14, hiddenStaves: [],
            hasSeededAuthoredVisibility: true,
        )
        let result = await makeStore(repo).loadOrSeed(authoredHiddenStaves: [authored])
        #expect(result.hiddenStaves.isEmpty)
        #expect(repo.savedReaderPreferences.isEmpty)
    }
}
