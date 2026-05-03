import Domain
import Foundation
@testable import Reader
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
            score: Score(division: 480, parts: [], staves: [], metaTags: [:]),
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
        #expect(vm.preferences.hiddenStaffIDs.isEmpty)
        #expect(repo.savedReaderPreferences.count == 1)
    }

    @Test func loadUsesPersistedPreferencesWhenPresent() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 18, hiddenStaffIDs: [2]
        )
        let gateway = FakeScoreFileGateway()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14
        )

        await vm.load()
        #expect(vm.preferences.staffSize == 18)
        #expect(vm.preferences.hiddenStaffIDs == [2])
        // No new save because the persisted record is reused as-is.
        #expect(repo.savedReaderPreferences.isEmpty)
    }

    @Test func incrementAndDecrementStaffSizePersist() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 14, hiddenStaffIDs: []
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
            scoreItemID: item.id, staffSize: 8, hiddenStaffIDs: []
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
            scoreItemID: item.id, staffSize: 14, hiddenStaffIDs: []
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14
        )
        await vm.load()
        await vm.toggleStaff(id: 2)
        #expect(vm.preferences.hiddenStaffIDs == [2])
        await vm.toggleStaff(id: 2)
        #expect(vm.preferences.hiddenStaffIDs.isEmpty)
    }

    @Test func showAllAndHideAllAreBulkOperations() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 14, hiddenStaffIDs: [0, 2]
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14
        )
        await vm.load()
        await vm.showAllStaves()
        #expect(vm.preferences.hiddenStaffIDs.isEmpty)
        await vm.hideAllStaves(allStaffIDs: [0, 1, 2])
        #expect(vm.preferences.hiddenStaffIDs == [0, 1, 2])
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
