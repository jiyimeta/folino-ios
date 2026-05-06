import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@Suite @MainActor
struct ReaderViewModelTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    @Test func successfulLoadTransitionsToLoadedAndUpdatesLastOpened() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let gateway = FakeScoreFileGateway()
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp")
        )

        await vm.load()
        if case .loaded = vm.loadState {} else {
            Issue.record("expected .loaded, got \(vm.loadState)")
        }
        #expect(repo.savedScoreItems.count == 1)
        #expect(repo.savedScoreItems.first?.lastOpenedAt != nil)
    }

    @Test func loadFailureTransitionsToFailedAndDoesNotSave() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let gateway = FakeScoreFileGateway(
            loadScoreResult: .failure(.scoreFileNotFound(name: "test.mscx"))
        )
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp")
        )

        await vm.load()
        if case .failed = vm.loadState {} else {
            Issue.record("expected .failed, got \(vm.loadState)")
        }
        #expect(repo.savedScoreItems.isEmpty)
    }

    @Test func reloadAfterFailureSucceeds() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let gateway = FakeScoreFileGateway(
            loadScoreResult: .failure(.scoreParseFailed(reason: "bad"))
        )
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp")
        )
        await vm.load()
        if case .failed = vm.loadState {} else {
            Issue.record("expected initial failure")
        }

        gateway.loadScoreResult = .success((
            score: Score(division: 480, parts: [], metaTags: [:]),
            summary: ScoreFileSummary(
                title: "Test", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
        ))
        await vm.load()
        if case .loaded = vm.loadState {} else {
            Issue.record("expected .loaded after retry, got \(vm.loadState)")
        }
    }

    @Test func firstOpenPopulatesDeviceClassDefaultStaffSize() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let gateway = FakeScoreFileGateway()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 11 // simulates iPhone compact
        )

        await vm.load()
        #expect(vm.preferences.staffSize == 11)
        #expect(vm.preferences.hiddenStaves.isEmpty)
        #expect(repo.savedReaderPreferences.count == 1)
    }

    @Test func loadUsesPersistedPreferencesWhenPresent() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let hidden: Set<StaffAddress> = [StaffAddress(partIndex: 1, staffIndexInPart: 0)]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 18, hiddenStaves: hidden
        )
        let gateway = FakeScoreFileGateway()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14
        )

        await vm.load()
        #expect(vm.preferences.staffSize == 18)
        #expect(vm.preferences.hiddenStaves == hidden)
        // No new save because the persisted record is reused as-is.
        #expect(repo.savedReaderPreferences.isEmpty)
    }

    @Test func incrementAndDecrementStaffSizePersist() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 14, hiddenStaves: []
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14
        )
        await vm.load()
        await vm.incrementStaffSize()
        #expect(vm.preferences.staffSize == 15)
        await vm.decrementStaffSize()
        await vm.decrementStaffSize()
        #expect(vm.preferences.staffSize == 13)
        // 1 save from each mutator.
        #expect(repo.savedReaderPreferences.count == 3)
    }

    @Test func staffSizeIsClampedToMinAndMax() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 8, hiddenStaves: []
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14
        )
        await vm.load()
        await vm.decrementStaffSize()
        #expect(vm.preferences.staffSize == 8) // already at min, stays at min
        for _ in 0 ..< 25 { await vm.incrementStaffSize() }
        #expect(vm.preferences.staffSize == 28) // capped
    }

    @Test func toggleStaffFlipsMembership() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 14, hiddenStaves: []
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14
        )
        await vm.load()
        let address = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        await vm.toggleStaff(address: address)
        #expect(vm.preferences.hiddenStaves == [address])
        await vm.toggleStaff(address: address)
        #expect(vm.preferences.hiddenStaves.isEmpty)
    }

    @Test func playbackCursorMirrorsControllerStream() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        let target = ScoreCursor.beat(measureIndex: 4, tickInMeasure: 240)
        controller.cursorContinuation.yield(target)
        // Allow the AsyncStream consumer Task to schedule.
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(vm.playbackCursor == target)

        controller.cursorContinuation.yield(nil)
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(vm.playbackCursor == nil)
    }

    @Test func togglePlaybackLoadsPlaysThenPauses() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:]
        )
        let gateway = FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "Test", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
        )))
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        await vm.togglePlayback()
        #expect(controller.loadCount == 1)
        #expect(controller.playCount == 1)
        #expect(vm.isPlaying)

        await vm.togglePlayback()
        #expect(controller.pauseCount == 1)
        #expect(controller.loadCount == 1) // load only happens once
        #expect(!vm.isPlaying)
    }

    @Test func togglePlaybackIsNoOpWhenScoreNotLoaded() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        // No `await vm.load()`.
        await vm.togglePlayback()
        #expect(controller.loadCount == 0)
        #expect(controller.playCount == 0)
        #expect(!vm.isPlaying)
    }

    @Test func setVolumeForwardsToControllerByFlatStaffIndex() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()]),
                Part(id: "P1", trackName: "Pno", instrument: Instrument(id: "p"), staves: [Staff(), Staff()]),
            ],
            metaTags: [:]
        )
        let gateway = FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "Test", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
        )))
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        // Piano's lower staff is at (partIndex: 1, staffIndexInPart: 1)
        // → flat staff index 2 (Vn=0, Pno-top=1, Pno-bottom=2).
        let pianoBottom = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        vm.setVolume(0.3, for: pianoBottom)
        // Allow the dispatched `Task { await controller.setStaffVolume(...) }` to run.
        await Task.yield()
        await Task.yield()
        #expect(controller.staffVolumes[2] == 0.3)
    }

    @Test func staffVolumeDefaultsToOneAndIsClampedOnSet() {
        let vm = makeVMNoLoad()
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        #expect(vm.volume(for: address) == 1.0)

        vm.setVolume(0.4, for: address)
        #expect(vm.volume(for: address) == 0.4)
        #expect(vm.staffVolumes[address] == 0.4)

        vm.setVolume(-0.5, for: address)
        #expect(vm.volume(for: address) == 0)
        vm.setVolume(2.0, for: address)
        #expect(vm.volume(for: address) == 1.0)
    }

    @Test func resetZoomReturnsToUnitAndZeroPan() {
        let vm = makeVMNoLoad()
        vm.viewportZoom = 2.5
        vm.viewportPan = .init(width: 100, height: -50)
        vm.resetZoom()
        #expect(vm.viewportZoom == 1.0)
        #expect(vm.viewportPan == .zero)
    }

    @Test func toggleZoomGoesFromUnitToTargetThenBack() {
        let vm = makeVMNoLoad()
        #expect(vm.viewportZoom == 1.0)
        vm.toggleZoom(targetIfZoomedOut: 2.0)
        #expect(vm.viewportZoom == 2.0)
        vm.toggleZoom(targetIfZoomedOut: 2.0)
        #expect(vm.viewportZoom == 1.0)
    }

    @Test func toggleZoomRestoresLastNonUnitZoom() {
        let vm = makeVMNoLoad()
        vm.viewportZoom = 3.5
        vm.captureCurrentZoomAsLast()
        vm.resetZoom()
        vm.toggleZoom(targetIfZoomedOut: 2.0)
        #expect(vm.viewportZoom == 3.5) // last remembered, not the default arg
    }

    @Test func chromeAndInspectorAreToggleable() {
        let vm = makeVMNoLoad()
        #expect(vm.isChromeVisible)
        vm.toggleChrome()
        #expect(!vm.isChromeVisible)
        vm.toggleChrome()
        #expect(vm.isChromeVisible)

        #expect(!vm.isInspectorPresented)
        vm.isInspectorPresented = true
        #expect(vm.isInspectorPresented)
    }

    private func makeVMNoLoad() -> ReaderViewModel {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        return ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14
        )
    }
}
