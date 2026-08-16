import Domain
@testable import Editor
import Foundation
import Testing

@MainActor
@Suite("EditorViewModel revert")
struct EditorViewModelRevertTests {
    private func makeTempScoresDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "editor-revert-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeViewModel(
        item: ScoreItem,
        originalStore: FakeScoreOriginalStore,
        gateway: FakeScoreFileGateway = FakeScoreFileGateway(),
        repository: FakeScoreLibraryRepository = FakeScoreLibraryRepository(),
        directory: URL,
    ) -> EditorViewModel {
        EditorViewModel(
            scoreItem: item,
            scoresDirectory: directory,
            gateway: gateway,
            repository: repository,
            originalStore: originalStore,
            playback: nil,
        )
    }

    private func capturedItem() -> ScoreItem {
        var item = EditorFixtures.sampleItem()
        item.originalFileName = "score.original.mscz"
        item.originalContentHash = "orig"
        item.originalProvenance = .importTime
        return item
    }

    @Test func `revert is unavailable until an original exists`() {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = makeViewModel(
            item: EditorFixtures.sampleItem(),
            originalStore: FakeScoreOriginalStore(),
            directory: dir,
        )
        #expect(vm.canRevertToOriginal == false)
    }

    @Test func `revert is available once an original exists`() {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = makeViewModel(item: capturedItem(), originalStore: FakeScoreOriginalStore(), directory: dir)
        #expect(vm.canRevertToOriginal)
    }

    /// The bug this guards: going through `endSession()` would flush the pending autosave and write the very edits
    /// being discarded, one moment before discarding them.
    @Test func `reverting does not write the pending edit first`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = FakeScoreFileGateway()
        let store = FakeScoreOriginalStore()
        let vm = makeViewModel(item: capturedItem(), originalStore: store, gateway: gateway, directory: dir)
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))

        await vm.revertToOriginal()

        #expect(gateway.savedCalls.isEmpty)
        #expect(store.revertCalls.count == 1)
        #expect(store.revertCalls.first?.1 == false)
    }

    @Test func `reverting persists the rebuilt row and notifies the host`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let vm = makeViewModel(
            item: capturedItem(),
            originalStore: FakeScoreOriginalStore(),
            repository: repository,
            directory: dir,
        )
        var notified: ScoreItem?
        vm.onRevertCompleted = { notified = $0 }
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))

        await vm.revertToOriginal()

        #expect(repository.savedScoreItems.count == 1)
        #expect(notified?.id == vm.scoreItem.id)
        #expect(vm.canUndo == false)
    }

    /// The bug this guards: `revertToOriginal` used to clear `isDirty` before attempting the revert, so a failure
    /// left the session open with a live edit the view model no longer believed needed protecting — a later flush
    /// (scene going inactive, say) would silently drop it. Here the STORE call is the one that throws, so the file
    /// was never touched — the pre-revert edit is exactly as live as before, and must stay protected.
    @Test func `a failed store revert keeps the session open and reschedules the autosave`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = FakeScoreFileGateway()
        let store = FakeScoreOriginalStore()
        store.revertError = DomainError.persistenceFailed(reason: "test")
        let vm = makeViewModel(item: capturedItem(), originalStore: store, gateway: gateway, directory: dir)
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))

        await vm.revertToOriginal()

        #expect(vm.canUndo)
        #expect(vm.revertError != nil)
        #expect(vm.isDirty)

        // The debounce this rescheduled on failure is what protects the surviving edit — a flush must still reach
        // the gateway rather than finding nothing to save.
        await vm.flushPendingSave()
        #expect(gateway.savedCalls.count == 1)
    }

    /// The bug this guards: a naive fix rescheduled the autosave on ANY thrown error, including this one — where the
    /// STORE call already succeeded (the file on disk is genuinely the original) and only the ROW save failed. A
    /// rescheduled autosave there would fire a couple seconds later and silently write the in-memory EDITED score
    /// back over the file this just restored, with no sidecar left to recover the original from. Nothing may
    /// schedule a write for the rest of this session once the store call has returned.
    @Test func `a failed row save after a successful store revert tears down without resaving the edit`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = FakeScoreFileGateway()
        let repository = FakeScoreLibraryRepository()
        repository.saveError = DomainError.persistenceFailed(reason: "test")
        let vm = makeViewModel(
            item: capturedItem(),
            originalStore: FakeScoreOriginalStore(),
            gateway: gateway,
            repository: repository,
            directory: dir,
        )
        var notified: ScoreItem?
        vm.onRevertCompleted = { notified = $0 }
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))

        await vm.revertToOriginal()

        #expect(vm.canUndo == false)
        #expect(vm.revertError != nil)
        #expect(notified != nil)

        // The assertion that matters: the store already reverted the file, so a subsequent flush must find nothing
        // to save. If it reaches the gateway, the in-memory edit just got written back over the restored original.
        await vm.flushPendingSave()
        #expect(gateway.savedCalls.isEmpty)
    }

    /// Critical 1: `EditorViewModel` is created once and reused for every edit session a Reader screen opens, so
    /// nothing but an explicit refresh ever updates `scoreItem` between sessions. A revert performed through the
    /// score-info sheet writes through a DIFFERENT view model's copy of the row, so without `refreshRow(_:)` this
    /// instance would still believe an original is captured under a sidecar the store has already deleted — the
    /// next save's capture step would see "already captured" and silently skip it, destroying the original a
    /// second time with no backup. `refreshRow(_:)` is the fix's seam (wired in production by
    /// `EditableReaderScreen.wireOnce()`'s `onBeginEditing`, before `beginSession`); this test exercises it
    /// directly, one layer below the App composition root.
    @Test func `a fresh row adopted after an external revert re-enables capture on the next save`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = FakeScoreFileGateway()
        let store = FakeScoreOriginalStore()
        let vm = makeViewModel(item: capturedItem(), originalStore: store, gateway: gateway, directory: dir)

        // Simulate the score-info sheet reverting this same row through ITS OWN copy: the Editor's own `scoreItem`
        // never sees it unless something refreshes it.
        var revertedElsewhere = capturedItem()
        revertedElsewhere.originalFileName = nil
        revertedElsewhere.originalContentHash = nil
        revertedElsewhere.originalProvenance = nil
        vm.refreshRow(revertedElsewhere)

        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))
        await vm.flushPendingSave()

        #expect(store.captureCalls.count == 1)
        #expect(gateway.savedCalls.count == 1)
        #expect(vm.canRevertToOriginal)
    }

    /// A `refreshRow(_:)` naming a DIFFERENT item's id must be ignored — adopting it would silently start acting on
    /// the wrong score's row.
    @Test func `refreshRow ignores an item for a different id`() {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = makeViewModel(item: capturedItem(), originalStore: FakeScoreOriginalStore(), directory: dir)
        var other = EditorFixtures.sampleItem()
        other.originalFileName = nil
        #expect(other.id != vm.scoreItemID)

        vm.refreshRow(other)

        #expect(vm.canRevertToOriginal)
    }

    /// Critical 2: `performSave()`'s one real suspension is inside `captureOriginalIfNeeded` (the live store runs
    /// it `Task.detached`), so cancelling `autosaveTask` — which `revertToOriginal()` does up front — cannot reach
    /// a save already past the entry guard and suspended there. Without the fix, that save resumes once the gate
    /// opens and runs straight through to `gateway.saveScore`, landing the edit back over whatever the concurrent
    /// revert just restored, with the sidecar already gone. `flushPendingSave()` stands in for either real trigger
    /// (the debounce firing mid-confirmation, or `EditableReaderScreen`'s scene-background flush) — both funnel
    /// through the same `performSave()` choke point this guards.
    @Test func `an in-flight save is serialized against a concurrent revert and never reaches the gateway`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = FakeScoreFileGateway()
        let store = FakeScoreOriginalStore()
        let gate = CaptureGate()
        store.captureGate = gate
        let vm = makeViewModel(item: capturedItem(), originalStore: store, gateway: gateway, directory: dir)
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))

        // Drive the save ourselves (bypassing the 2 s debounce) — the same choke point either real trigger uses.
        let saveTask = Task { await vm.flushPendingSave() }
        // Don't race the view model's own Task scheduling: wait until the save is actually inside
        // `captureOriginalIfNeeded`, past `performSave()`'s entry guard, before starting the revert.
        await gate.waitUntilEntered()
        // Opens the gate from a SEPARATE Task so `revertToOriginal()` can be awaited directly below, on this test's
        // own task: that runs its synchronous prefix (setting `isReverting`) immediately and deterministically —
        // no scheduling race — before anything can resume the still-suspended save.
        let openerTask = Task { await gate.open() }
        await vm.revertToOriginal()
        await saveTask.value
        await openerTask.value

        #expect(gateway.savedCalls.isEmpty)
        #expect(store.revertCalls.count == 1)
    }

    @Test func `a legacy original carries its caveat into the warnings`() {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var item = capturedItem()
        item.originalProvenance = .legacyUnknown
        let vm = makeViewModel(item: item, originalStore: FakeScoreOriginalStore(), directory: dir)
        let warnings = vm.revertWarnings(hasMusicalAnnotations: false)
        #expect(warnings.contains(.originalMayNotBeImportTime))
    }
}
