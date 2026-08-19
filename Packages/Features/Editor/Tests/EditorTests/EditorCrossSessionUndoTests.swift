import Domain
@testable import Editor
import Foundation
import SheetMusicUI
import Testing

/// The history's life across sessions: deposited at session end, adopted back at the next `beginSession` on the
/// same bytes, and never deposited dirty, empty, or under different bytes. The store here is the recording fake —
/// the concrete LRU lives in the App target with its own suite.
@MainActor
@Suite("EditorViewModel cross-session history")
struct EditorCrossSessionUndoTests {
    private func makeTempScoresDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "editor-history-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeViewModel(
        store: FakeScoreEditHistoryStore,
        gateway: FakeScoreFileGateway = FakeScoreFileGateway(),
        directory: URL,
    ) -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: directory,
            gateway: gateway,
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            historyStore: store,
            playback: nil,
        )
    }

    @Test func `endSession deposits a session with history and the next beginSession adopts it`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let vm = makeViewModel(store: store, directory: dir)
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        let editedScore = try #require(vm.score)
        await vm.endSession()

        #expect(store.retained.count == 1)
        #expect(store.retained.first?.id == vm.scoreItemID)
        // The deposit is keyed by the row's POST-flush contentHash — the digest of exactly the bytes the
        // session's score was saved as.
        #expect(store.retained.first?.contentHash == vm.scoreItem.contentHash)
        #expect(!vm.isSessionActive)

        vm.beginSession(score: editedScore)
        #expect(vm.canUndo) // the history crossed the session boundary
        vm.undo()
        #expect(vm.score == EditorFixtures.fourQuarterRests()) // the PREVIOUS session's edit, undone
    }

    @Test func `an untouched session is not deposited`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let vm = makeViewModel(store: store, directory: dir)
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        await vm.endSession()
        #expect(store.retained.isEmpty)
    }

    @Test func `a failed final save discards the session instead of depositing it`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let gateway = FakeScoreFileGateway()
        gateway.saveError = DomainError.persistenceFailed(reason: "test")
        let vm = makeViewModel(store: store, gateway: gateway, directory: dir)
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        await vm.endSession()
        // The flush left `isDirty == true`: depositing would retain a history whose bytes never reached the disk.
        // Discarding is exactly today's failed-final-save contract.
        #expect(store.retained.isEmpty)
    }

    @Test func `a deposit under different bytes is not adopted, and the stale entry is dropped`() {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let vm = makeViewModel(store: store, directory: dir)
        // A previous run deposited under bytes this row no longer has (reverted / re-imported / restored since).
        store.retain(
            ScoreEditSession(score: EditorFixtures.chordAtIndex1()),
            for: vm.scoreItemID,
            contentHash: "not-the-row's-digest",
        )
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        #expect(!vm.canUndo) // fresh session, no history
        #expect(store.retained.isEmpty) // the checkout's hash guard dropped the stale entry
        // And the view model asked with the ROW's hash — the guard the whole keying scheme rests on.
        #expect(store.sessionRequests.first?.contentHash == vm.scoreItem.contentHash)
    }
}
