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
    /// (scene going inactive, say) would silently drop it.
    @Test func `a failed revert keeps the session open and reschedules the autosave`() async {
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
