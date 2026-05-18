import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderViewModelRepeatTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    private static func makeVM(
        controller: FakePlaybackController = FakePlaybackController(),
        repo: FakeScoreLibraryRepository = FakeScoreLibraryRepository(),
    ) -> (ReaderViewModel, FakePlaybackController, FakeScoreLibraryRepository) {
        let item = Self.makeItem()
        repo.scoreItems = [item]
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        return (vm, controller, repo)
    }

    @Test func `repeat mode defaults to off`() async {
        let (vm, _, _) = Self.makeVM()
        await vm.load()
        #expect(vm.repeatModel.mode == .off)
    }

    @Test func `set repeat mode persists`() async {
        let (vm, _, repo) = Self.makeVM()
        await vm.load()

        await vm.repeatModel.setMode(.loopAll)
        #expect(vm.repeatModel.mode == .loopAll)
        #expect(repo.savedReaderPreferences.last?.repeatMode == .loopAll)

        await vm.repeatModel.setMode(.abLoop)
        #expect(vm.repeatModel.mode == .abLoop)
        #expect(repo.savedReaderPreferences.last?.repeatMode == .abLoop)

        await vm.repeatModel.setMode(.off)
        #expect(vm.repeatModel.mode == .off)
        #expect(repo.savedReaderPreferences.last?.repeatMode == .off)
    }

    @Test func `set repeat A snaps to cursor measure head`() async {
        let (vm, _, repo) = Self.makeVM()
        await vm.load()
        vm.setManualCursor(.beat(measureIndex: 4, tickInMeasure: 0))

        await vm.repeatModel.setA()

        // A is set; B is not — loop is incomplete so abRepeat stays nil. The pending marker is reflected in
        // pendingRepeatA.
        #expect(vm.repeatModel.pendingRepeatA?.measureIndex == 4)
        #expect(vm.repeatModel.pendingRepeatA?.chordIndex == 0)
        #expect(vm.repeatModel.abRange == nil)
        #expect(repo.savedReaderPreferences.last?.abRepeat == nil)
    }

    @Test func `set repeat B snaps to cursor measure end`() async {
        let (vm, _, _) = Self.makeVM()
        await vm.load()
        vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))

        await vm.repeatModel.setB()

        // FakeScoreFileGateway loads a 6-measure score; m1 has 2 chord positions (indices 0 and 1), so the snapped end
        // ChordPath has measureIndex == 1 and chordIndex == 1. B-only → loop is incomplete; abRepeat is nil;
        // pendingRepeatB reflects the snap.
        #expect(vm.repeatModel.pendingRepeatB?.measureIndex == 1)
        #expect(vm.repeatModel.pendingRepeatB?.chordIndex == 1)
        #expect(vm.repeatModel.abRange == nil)
    }

    @Test func `set repeat A replaces previous A value`() async {
        let (vm, _, _) = Self.makeVM()
        await vm.load()

        vm.setManualCursor(.beat(measureIndex: 2, tickInMeasure: 0))
        await vm.repeatModel.setA()
        vm.setManualCursor(.beat(measureIndex: 5, tickInMeasure: 0))
        await vm.repeatModel.setA()

        // Still no B set — loop incomplete, abRepeat is nil. The pending A marker is updated to m5.
        #expect(vm.repeatModel.pendingRepeatA?.measureIndex == 5)
        #expect(vm.repeatModel.abRange == nil)
    }

    @Test func `clear repeat A removes start but keeps end`() async {
        let (vm, _, _) = Self.makeVM()
        await vm.load()
        vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
        await vm.repeatModel.setA()
        await vm.repeatModel.setB()
        #expect(vm.repeatModel.abRange != nil)

        await vm.repeatModel.clearA()

        // Once start is cleared and end remains, the persisted record drops the range entirely (loop is incomplete) but
        // keeps the B marker for re-display via a separate `pendingB` accessor.
        #expect(vm.repeatModel.abRange == nil)
        #expect(vm.repeatModel.pendingRepeatB?.measureIndex == 1)
    }

    @Test func `clear repeat B removes end but keeps start`() async {
        let (vm, _, _) = Self.makeVM()
        await vm.load()
        vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
        await vm.repeatModel.setA()
        await vm.repeatModel.setB()

        await vm.repeatModel.clearB()

        #expect(vm.repeatModel.abRange == nil)
        #expect(vm.repeatModel.pendingRepeatA?.measureIndex == 1)
    }

    @Test func `set repeat mode forwards loop range`() async {
        let (vm, controller, _) = Self.makeVM()
        await vm.load()

        await vm.repeatModel.setMode(.loopAll)
        #expect(controller.loopRangeCalls.last??.start.measureIndex == 0)

        await vm.repeatModel.setMode(.abLoop)
        #expect(controller.loopRangeCalls.last == .some(nil))

        await vm.repeatModel.setMode(.off)
        #expect(controller.loopRangeCalls.last == .some(nil))
    }

    @Test func `set repeat A only does not forward loop range yet`() async {
        let (vm, controller, _) = Self.makeVM()
        await vm.load()
        await vm.repeatModel.setMode(.abLoop)
        let countBefore = controller.loopRangeCalls.count
        vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))

        await vm.repeatModel.setA()

        // One additional call recorded, value is `nil` (B still unset).
        #expect(controller.loopRangeCalls.count == countBefore + 1)
        #expect(controller.loopRangeCalls.last == .some(nil))
    }

    @Test func `both markers set forwards the normalized range`() async {
        let (vm, controller, _) = Self.makeVM()
        await vm.load()
        await vm.repeatModel.setMode(.abLoop)
        vm.setManualCursor(.beat(measureIndex: 2, tickInMeasure: 0))
        await vm.repeatModel.setA()
        vm.setManualCursor(.beat(measureIndex: 0, tickInMeasure: 0))

        await vm.repeatModel.setB()

        // Auto-swap: B at m0 + A at m2 -> normalized start=m0, end=m2. loopRangeCalls is [ABRepeatRange?]; .last is
        // (ABRepeatRange?)? flatMap collapses to ABRepeatRange? (outer=no calls, inner=nil call).
        let last: ABRepeatRange? = controller.loopRangeCalls.last.flatMap(\.self)
        #expect(last?.start.measureIndex == 0)
        #expect(last?.end.measureIndex == 2)
    }

    @Test func `persisted ab repeat is seeded into controller on playback prep`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let chord = ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 0)
        let endChord = ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0)
        let stored = ReaderPreferences(
            scoreItemID: item.id,
            staffSize: 14,
            hiddenStaves: [],
            repeatMode: .abLoop,
            abRepeat: ABRepeatRange(start: chord, end: endChord),
        )
        repo.storedReaderPreferences[item.id] = stored
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )

        await vm.load()
        await vm.prepareForPlayback()

        #expect(controller.lastLoadedPreferences?.abRepeat?.start == chord)
        #expect(controller.lastLoadedPreferences?.abRepeat?.end == endChord)
    }

    @Test func `persisted ab loop forwards loop range to controller on prep`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let chord = ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 0)
        let endChord = ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0)
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id,
            staffSize: 14,
            hiddenStaves: [],
            repeatMode: .abLoop,
            abRepeat: ABRepeatRange(start: chord, end: endChord),
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )

        await vm.load()
        await vm.prepareForPlayback()

        let last: ABRepeatRange? = controller.loopRangeCalls.last.flatMap(\.self)
        #expect(last?.start == chord)
        #expect(last?.end == endChord)
    }

    @Test func `persisted loop all forwards full score range to controller on prep`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id,
            staffSize: 14,
            hiddenStaves: [],
            repeatMode: .loopAll,
            abRepeat: nil,
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )

        await vm.load()
        await vm.prepareForPlayback()

        // Fixture: 6 measures, two chord-positions per measure. Full range = m0.chord0 .. m5.chord1.
        let last: ABRepeatRange? = controller.loopRangeCalls.last.flatMap(\.self)
        #expect(last?.start.measureIndex == 0)
        #expect(last?.start.chordIndex == 0)
        #expect(last?.end.measureIndex == 5)
        #expect(last?.end.chordIndex == 1)
    }

    @Test func `toggling playback without prep also forwards persisted loop range`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let chord = ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 0)
        let endChord = ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0)
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id,
            staffSize: 14,
            hiddenStaves: [],
            repeatMode: .abLoop,
            abRepeat: ABRepeatRange(start: chord, end: endChord),
        )
        let controller = FakePlaybackController()
        controller.soundfontsAvailableLocally = true
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )

        await vm.load()
        // Skip prepareForPlayback — exercise the lazy-load path inside togglePlayback.
        await vm.togglePlayback()

        let last: ABRepeatRange? = controller.loopRangeCalls.last.flatMap(\.self)
        #expect(last?.start == chord)
        #expect(last?.end == endChord)
    }
}
