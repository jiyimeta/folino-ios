import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@Suite @MainActor
struct ReaderViewModelRepeatTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    private static func makeVM(
        controller: FakePlaybackController = FakePlaybackController(),
        repo: FakeScoreLibraryRepository = FakeScoreLibraryRepository()
    ) -> (ReaderViewModel, FakePlaybackController, FakeScoreLibraryRepository) {
        let item = Self.makeItem()
        repo.scoreItems = [item]
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        return (vm, controller, repo)
    }

    @Test func repeatModeDefaultsToOff() async {
        let (vm, _, _) = Self.makeVM()
        await vm.load()
        #expect(vm.repeatMode == .off)
    }

    @Test func advanceRepeatModeCyclesAndPersists() async {
        let (vm, _, repo) = Self.makeVM()
        await vm.load()

        await vm.advanceRepeatMode()
        #expect(vm.repeatMode == .loopAll)
        #expect(repo.savedReaderPreferences.last?.repeatMode == .loopAll)

        await vm.advanceRepeatMode()
        #expect(vm.repeatMode == .abLoop)
        #expect(repo.savedReaderPreferences.last?.repeatMode == .abLoop)

        await vm.advanceRepeatMode()
        #expect(vm.repeatMode == .off)
        #expect(repo.savedReaderPreferences.last?.repeatMode == .off)
    }

    @Test func setRepeatASnapsToCursorMeasureHead() async {
        let (vm, _, repo) = Self.makeVM()
        await vm.load()
        vm.setManualCursor(.beat(measureIndex: 4, tickInMeasure: 0))

        await vm.setRepeatA()

        // A is set; B is not — loop is incomplete so abRepeat stays nil.
        // The pending marker is reflected in pendingRepeatA.
        #expect(vm.pendingRepeatA?.measureIndex == 4)
        #expect(vm.pendingRepeatA?.chordIndex == 0)
        #expect(vm.abRepeat == nil)
        #expect(repo.savedReaderPreferences.last?.abRepeat == nil)
    }

    @Test func setRepeatBSnapsToCursorMeasureEnd() async {
        let (vm, _, _) = Self.makeVM()
        await vm.load()
        vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))

        await vm.setRepeatB()

        // FakeScoreFileGateway loads a 6-measure score; m1 has 2 chord
        // positions (indices 0 and 1), so the snapped end ChordPath has
        // measureIndex == 1 and chordIndex == 1.
        // B-only → loop is incomplete; abRepeat is nil; pendingRepeatB reflects the snap.
        #expect(vm.pendingRepeatB?.measureIndex == 1)
        #expect(vm.pendingRepeatB?.chordIndex == 1)
        #expect(vm.abRepeat == nil)
    }

    @Test func setRepeatAReplacesPreviousAValue() async {
        let (vm, _, _) = Self.makeVM()
        await vm.load()

        vm.setManualCursor(.beat(measureIndex: 2, tickInMeasure: 0))
        await vm.setRepeatA()
        vm.setManualCursor(.beat(measureIndex: 5, tickInMeasure: 0))
        await vm.setRepeatA()

        // Still no B set — loop incomplete, abRepeat is nil.
        // The pending A marker is updated to m5.
        #expect(vm.pendingRepeatA?.measureIndex == 5)
        #expect(vm.abRepeat == nil)
    }

    @Test func clearRepeatARemovesStartButKeepsEnd() async {
        let (vm, _, _) = Self.makeVM()
        await vm.load()
        vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
        await vm.setRepeatA()
        await vm.setRepeatB()
        #expect(vm.abRepeat != nil)

        await vm.clearRepeatA()

        // Once start is cleared and end remains, the persisted record drops
        // the range entirely (loop is incomplete) but keeps the B marker
        // for re-display via a separate `pendingB` accessor.
        #expect(vm.abRepeat == nil)
        #expect(vm.pendingRepeatB?.measureIndex == 1)
    }

    @Test func clearRepeatBRemovesEndButKeepsStart() async {
        let (vm, _, _) = Self.makeVM()
        await vm.load()
        vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
        await vm.setRepeatA()
        await vm.setRepeatB()

        await vm.clearRepeatB()

        #expect(vm.abRepeat == nil)
        #expect(vm.pendingRepeatA?.measureIndex == 1)
    }

    @Test func advanceRepeatModeForwardsLoopRange() async {
        let (vm, controller, _) = Self.makeVM()
        await vm.load()

        await vm.advanceRepeatMode() // .off -> .loopAll
        #expect(controller.loopRangeCalls.last??.start.measureIndex == 0)

        await vm.advanceRepeatMode() // .loopAll -> .abLoop with no markers
        #expect(controller.loopRangeCalls.last == .some(nil))

        await vm.advanceRepeatMode() // .abLoop -> .off
        #expect(controller.loopRangeCalls.last == .some(nil))
    }

    @Test func setRepeatAOnlyDoesNotForwardLoopRangeYet() async {
        let (vm, controller, _) = Self.makeVM()
        await vm.load()
        await vm.advanceRepeatMode() // .loopAll
        await vm.advanceRepeatMode() // .abLoop
        let countBefore = controller.loopRangeCalls.count
        vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))

        await vm.setRepeatA()

        // One additional call recorded, value is `nil` (B still unset).
        #expect(controller.loopRangeCalls.count == countBefore + 1)
        #expect(controller.loopRangeCalls.last == .some(nil))
    }

    @Test func bothMarkersSetForwardsTheNormalizedRange() async {
        let (vm, controller, _) = Self.makeVM()
        await vm.load()
        await vm.advanceRepeatMode() // .loopAll
        await vm.advanceRepeatMode() // .abLoop
        vm.setManualCursor(.beat(measureIndex: 2, tickInMeasure: 0))
        await vm.setRepeatA()
        vm.setManualCursor(.beat(measureIndex: 0, tickInMeasure: 0))

        await vm.setRepeatB()

        // Auto-swap: B at m0 + A at m2 -> normalized start=m0, end=m2.
        // loopRangeCalls is [ABRepeatRange?]; .last is (ABRepeatRange?)?
        // flatMap collapses to ABRepeatRange? (outer=no calls, inner=nil call).
        let last: ABRepeatRange? = controller.loopRangeCalls.last.flatMap { $0 }
        #expect(last?.start.measureIndex == 0)
        #expect(last?.end.measureIndex == 2)
    }

    @Test func cursorPastEndDuringPlaybackSeeksToStartOfA() async throws {
        let (vm, controller, _) = Self.makeVM()
        await vm.load()
        await vm.advanceRepeatMode() // .loopAll
        await vm.advanceRepeatMode() // .abLoop
        vm.setManualCursor(.beat(measureIndex: 0, tickInMeasure: 0))
        await vm.setRepeatA()
        vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
        await vm.setRepeatB()
        vm.startObservingCursor()

        // Begin playback so the wrap gate (`isPlaying`) opens.
        await vm.togglePlayback()
        let setCursorCountBefore = controller.recordedSetCursorCalls.count

        // Engine emits a cursor in m=2 — past the loop end of m=1.
        controller.emitCursor(.beat(measureIndex: 2, tickInMeasure: 0))
        await Task.yield()

        let lastSeek = controller.recordedSetCursorCalls.last
        #expect(controller.recordedSetCursorCalls.count == setCursorCountBefore + 1)
        if case let .beat(measureIndex, tick) = lastSeek {
            #expect(measureIndex == 0)
            #expect(tick == 0)
        } else {
            Issue.record("expected a .beat cursor seek")
        }
    }

    @Test func cursorWithinLoopDoesNotTriggerSeek() async {
        let (vm, controller, _) = Self.makeVM()
        await vm.load()
        await vm.advanceRepeatMode()
        await vm.advanceRepeatMode()
        vm.setManualCursor(.beat(measureIndex: 0, tickInMeasure: 0))
        await vm.setRepeatA()
        vm.setManualCursor(.beat(measureIndex: 2, tickInMeasure: 0))
        await vm.setRepeatB()
        vm.startObservingCursor()
        await vm.togglePlayback()
        let setCursorCountBefore = controller.recordedSetCursorCalls.count

        controller.emitCursor(.beat(measureIndex: 1, tickInMeasure: 240))
        await Task.yield()

        #expect(controller.recordedSetCursorCalls.count == setCursorCountBefore)
    }

    @Test func cursorWrapDoesNotFireWhilePaused() async {
        let (vm, controller, _) = Self.makeVM()
        await vm.load()
        await vm.advanceRepeatMode()
        await vm.advanceRepeatMode()
        vm.setManualCursor(.beat(measureIndex: 0, tickInMeasure: 0))
        await vm.setRepeatA()
        vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
        await vm.setRepeatB()
        vm.startObservingCursor()
        // Note: NOT calling togglePlayback — isPlaying stays false.
        // Drain any pending Tasks (e.g. the setManualCursor dispatches) so
        // the `before` baseline is stable before the emit.
        await Task.yield()
        let before = controller.recordedSetCursorCalls.count

        controller.emitCursor(.beat(measureIndex: 2, tickInMeasure: 0))
        await Task.yield()

        #expect(controller.recordedSetCursorCalls.count == before)
    }

    @Test func nilCursorDuringLoopAllPlaybackWrapsToStart() async {
        let (vm, controller, _) = Self.makeVM()
        await vm.load()
        await vm.advanceRepeatMode() // .loopAll
        vm.startObservingCursor()
        await vm.togglePlayback()
        let before = controller.recordedSetCursorCalls.count

        // Engine signals end of score by nilling the cursor.
        controller.emitCursor(nil)
        await Task.yield()

        #expect(controller.recordedSetCursorCalls.count == before + 1)
        if case let .beat(measureIndex, _) = controller.recordedSetCursorCalls.last {
            #expect(measureIndex == 0)
        } else {
            Issue.record("expected a .beat cursor seek to measure 0")
        }
    }
}
