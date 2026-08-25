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
        originalStore: FakeScoreOriginalStore = FakeScoreOriginalStore(),
        directory: URL,
    ) -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: directory,
            gateway: gateway,
            repository: FakeScoreLibraryRepository(),
            originalStore: originalStore,
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

    // MARK: - Signed depth and the count-driven unwind (Task 8)

    /// Seeds one committed session so the next `beginSession` adopts real history, and returns the session-open
    /// score of the SECOND session (= the first session's edited result).
    private func seedOneCommittedEdit(into vm: EditorViewModel) async throws -> Score {
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        let edited = try #require(vm.score)
        await vm.endSession()
        return edited
    }

    @Test func `undo below the session start drives the depth negative and counts as edits to discard`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let vm = makeViewModel(store: store, directory: dir)
        let edited = try await seedOneCommittedEdit(into: vm)

        vm.beginSession(score: edited)
        #expect(vm.sessionEditDepth == 0)
        #expect(vm.sessionHasEdits == false)

        vm.undo() // reaches BELOW this session's start, into the previous session's history

        #expect(vm.sessionEditDepth == -1)
        // A session that net-undid earlier work has changed the score: ✕ must ask before throwing that away, and
        // the session-end control must read "edited".
        #expect(vm.sessionHasEdits)
        #expect(vm.sessionEndMode == .commitEdited)
    }

    @Test func `discarding a net-negative session redoes back to the session-open score`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let vm = makeViewModel(store: store, directory: dir)
        let edited = try await seedOneCommittedEdit(into: vm)

        vm.beginSession(score: edited)
        vm.undo()
        #expect(vm.score == EditorFixtures.fourQuarterRests())

        await vm.discardSessionEdits()

        // The unwind went FORWARD (redo) to land on the session-open score — the previous session's edit intact.
        #expect(vm.score == edited)
        #expect(vm.sessionEditDepth == 0)
    }

    @Test func `discard unwinds only this session's edits and ends all retained history for the score`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let vm = makeViewModel(store: store, directory: dir)
        let edited = try await seedOneCommittedEdit(into: vm)

        vm.beginSession(score: edited) // adopts — the store entry is checked out
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 2), pitch: 62, tpc: 16, duration: nil))

        await vm.discardSessionEdits()

        // Only THIS session's edit was unwound: the score is the session-open one, previous edit intact…
        #expect(vm.score == edited)
        // …and ✕ is final: the retained history is invalidated, and the exit's endSession must not deposit.
        #expect(store.invalidatedIDs == [vm.scoreItemID])
        await vm.endSession()
        #expect(store.retained.isEmpty)
        vm.beginSession(score: edited)
        #expect(!vm.canUndo) // the same contract as an app kill
    }

    @Test func `revertToOriginal invalidates the retained history`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        var item = EditorFixtures.sampleItem()
        item.originalFileName = "score.original.mscz"
        item.originalContentHash = "orig"
        item.originalProvenance = .importTime
        let vm = EditorViewModel(
            scoreItem: item,
            scoresDirectory: dir,
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            historyStore: store,
            playback: nil,
        )
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))

        await vm.revertToOriginal()

        // The file no longer relates to any retained history — dropped eagerly, not left for the lazy hash miss.
        #expect(store.invalidatedIDs == [vm.scoreItemID])
        #expect(store.retained.isEmpty)
    }

    // MARK: - Mixed directions, and two sessions overlapping in time (final-review fixes)

    /// Commits one session of TWO edits and deposits it, returning the score the NEXT session will open on. Two,
    /// not one, because the mixed-direction case needs room to undo below the session start and still have a step
    /// left over once a new edit has consumed one.
    private func seedTwoCommittedEdits(into vm: EditorViewModel) async throws -> Score {
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 2), pitch: 62, tpc: 16, duration: nil))
        let edited = try #require(vm.score)
        await vm.endSession()
        return edited
    }

    /// Drives a session into the state the count-driven unwind cannot walk out of: two undos below the session
    /// start, then a new edit — which `ScoreEditor.apply` pays for by clearing the redo stack the negative branch
    /// of the unwind depends on.
    private func undoBelowStartThenEdit(in vm: EditorViewModel, sessionOpen: Score) {
        vm.beginSession(score: sessionOpen) // adopts the deposited two-edit history
        vm.undo()
        vm.undo()
        #expect(vm.sessionEditDepth == -2)
        #expect(vm.score == EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 3), pitch: 64, tpc: 18, duration: nil))
        #expect(vm.sessionEditDepth == -1)
        #expect(!vm.canRedo) // the way back the depth counts on is gone
    }

    @Test
    func `discarding a session that undid below its start and then edited lands on the session-open score`(
    ) async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let gateway = FakeScoreFileGateway()
        let vm = makeViewModel(store: store, gateway: gateway, directory: dir)
        let sessionOpen = try await seedTwoCommittedEdits(into: vm)

        undoBelowStartThenEdit(in: vm, sessionOpen: sessionOpen)
        await vm.discardSessionEdits()

        // ✕ means ✕: the new note is gone AND the two rolled-back edits are back — this session's whole net effect,
        // in both directions, undone.
        #expect(vm.score == sessionOpen)
        #expect(vm.sessionEditDepth == 0)
        // …and the file says the same thing. Before the snapshot fallback this wrote the un-discarded score.
        #expect(gateway.savedCalls.last?.0 == sessionOpen)
    }

    @Test func `a session that undid once and then edited once still reports edited`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let vm = makeViewModel(store: store, directory: dir)
        let sessionOpen = try await seedOneCommittedEdit(into: vm)

        vm.beginSession(score: sessionOpen)
        vm.undo() // below this session's start, into the previous session's history
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 3), pitch: 64, tpc: 18, duration: nil))

        // The step count is back where it started while the score is not — so the count cannot be what the ✕
        // confirmation and the session-end control read, or the user loses that note without being asked.
        #expect(vm.sessionEditDepth == 0)
        #expect(vm.score != sessionOpen)
        #expect(vm.sessionHasEdits)
        #expect(vm.sessionEndMode == .commitEdited)
    }

    @Test func `a discard that cannot unwind writes nothing`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let gateway = FakeScoreFileGateway()
        let vm = makeViewModel(store: store, gateway: gateway, directory: dir)
        let sessionOpen = try await seedTwoCommittedEdits(into: vm)

        undoBelowStartThenEdit(in: vm, sessionOpen: sessionOpen)
        // The one state production cannot reach: a session with no way back at all. Whatever the reason, the
        // response has to be to write nothing — a file still holding this session's edits is recoverable, a
        // half-unwound score on disk is not.
        vm.forgetSessionOpenScoreForTesting()
        let savedBefore = gateway.savedCalls.count

        await vm.discardSessionEdits()

        #expect(vm.sessionEditDepth == -1) // never zeroed by loops that did not consume it
        #expect(gateway.savedCalls.count == savedBefore)
    }

    @Test func `closing a session whose edits cancelled out still ends its retained history`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let vm = makeViewModel(store: store, directory: dir)
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        vm.undo()
        // Net zero, so ✕ asks nothing and has nothing to unwind — but the session is still carrying that edit as a
        // redo, which is exactly what must not survive a ✕.
        #expect(vm.sessionEditDepth == 0)
        #expect(vm.canRedo)

        await vm.discardSessionEdits()
        #expect(store.invalidatedIDs == [vm.scoreItemID])
        await vm.endSession()
        #expect(store.retained.isEmpty)

        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        #expect(!vm.canUndo)
        #expect(!vm.canRedo)
    }

    @Test func `adopting a retained session tells the host which score it is now showing`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let vm = makeViewModel(store: store, directory: dir)
        let deposited = try await seedTwoCommittedEdits(into: vm)

        var announced: [Score] = []
        vm.onScoreChanged = { announced.append($0) }
        // The argument stands in for a Reader that parsed the file itself — a different value than the one the
        // store is holding. The adopted session's score is the session's score from here on, so the host has to be
        // told, rather than discovering it at the first undo.
        vm.beginSession(score: EditorFixtures.fourQuarterRests())

        #expect(announced == [deposited])
        #expect(vm.score == deposited)
    }

    @Test func `a session begun during the final flush is neither deposited nor wiped`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let originalStore = FakeScoreOriginalStore()
        let gate = CaptureGate()
        originalStore.captureGate = gate
        let vm = makeViewModel(store: store, originalStore: originalStore, directory: dir)
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        let ending = try #require(vm.session)

        // `endSession()` is fire-and-forget in the App and its flush is a real file write, so the user can be back
        // in edit mode before it returns.
        let exit = Task { await vm.endSession() }
        await gate.waitUntilEntered()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        let reopened = try #require(vm.session)
        await gate.open()
        await exit.value

        #expect(vm.isSessionActive) // the editor the user is looking at is still alive
        #expect(vm.session === reopened)
        #expect(store.retained.count == 1)
        #expect(store.retained.first?.session === ending) // the ENDING session was deposited, not the live one
    }
}
