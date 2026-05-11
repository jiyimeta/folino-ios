// swiftlint:disable file_length type_body_length
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

    @Test func volumeFallsBackToOneWhenLoadStateHasNoParts() {
        let vm = makeVMNoLoad()
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        #expect(vm.volume(for: address) == 1.0)
    }

    @Test func setVolumeClampsOutOfRangeValues() {
        let vm = makeVMNoLoad()
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        vm.setVolume(-0.5, for: address)
        #expect(vm.liveStaffVolumes[address] == 0)

        vm.setVolume(2.0, for: address)
        #expect(vm.liveStaffVolumes[address] == 1)
    }

    @Test func volumeUsesScoreCC7WhenNoOverride() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 64)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(loadScoreResult: .success((
                score: score,
                summary: ScoreFileSummary(
                    title: "T", composer: nil, instrumentationSummary: "",
                    lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
                )
            ))),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14
        )
        await vm.load()
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let value = vm.volume(for: address)
        #expect(abs(value - 64.0 / 127.0) < 0.0001)
    }

    @Test func volumeUsesPersistedOverrideWhenPresent() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id,
            staffSize: 14,
            hiddenStaves: [],
            staffVolumeOverrides: [address: 0.3]
        )
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 100)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(loadScoreResult: .success((
                score: score,
                summary: ScoreFileSummary(
                    title: "T", composer: nil, instrumentationSummary: "",
                    lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
                )
            ))),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14
        )
        await vm.load()
        #expect(vm.volume(for: address) == 0.3)
    }

    @Test func resetZoomReturnsToUnit() {
        let vm = makeVMNoLoad()
        vm.viewportZoom = 2.5
        vm.resetZoom()
        #expect(vm.viewportZoom == 1.0)
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

    @Test func inspectorIsToggleable() {
        let vm = makeVMNoLoad()
        #expect(!vm.isInspectorPresented)
        vm.isInspectorPresented = true
        #expect(vm.isInspectorPresented)
    }

    @Test func setHonorLayoutBreaksPersistsAndUpdatesPreferences() async {
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
        #expect(vm.preferences.honorLayoutBreaks == true)

        await vm.setHonorLayoutBreaks(false)
        #expect(vm.preferences.honorLayoutBreaks == false)
        #expect(repo.savedReaderPreferences.last?.honorLayoutBreaks == false)

        await vm.setHonorLayoutBreaks(true)
        #expect(vm.preferences.honorLayoutBreaks == true)
        #expect(repo.savedReaderPreferences.last?.honorLayoutBreaks == true)
    }

    @Test func setVolumeUpdatesLiveDictWithoutPersisting() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 100)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(loadScoreResult: .success((
                score: score,
                summary: ScoreFileSummary(
                    title: "T", composer: nil, instrumentationSummary: "",
                    lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
                )
            ))),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14
        )
        await vm.load()
        let savesBefore = repo.savedReaderPreferences.count

        vm.setVolume(0.4, for: address)

        #expect(vm.liveStaffVolumes[address] == 0.4)
        #expect(vm.volume(for: address) == 0.4)
        #expect(vm.preferences.staffVolumeOverrides[address] == nil)
        #expect(repo.savedReaderPreferences.count == savesBefore)
    }

    @Test func commitVolumePersistsOverrideAndClearsLiveValue() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 100)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(loadScoreResult: .success((
                score: score,
                summary: ScoreFileSummary(
                    title: "T", composer: nil, instrumentationSummary: "",
                    lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
                )
            ))),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14
        )
        await vm.load()
        vm.setVolume(0.4, for: address)
        let savesBefore = repo.savedReaderPreferences.count

        await vm.commitVolume(0.4, for: address)

        #expect(vm.preferences.staffVolumeOverrides[address] == 0.4)
        #expect(vm.liveStaffVolumes[address] == nil)
        #expect(vm.volume(for: address) == 0.4)
        #expect(repo.savedReaderPreferences.count == savesBefore + 1)
    }

    @Test func commitVolumeClampsOutOfRangeValues() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v"), staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(loadScoreResult: .success((
                score: score,
                summary: ScoreFileSummary(
                    title: "T", composer: nil, instrumentationSummary: "",
                    lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
                )
            ))),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14
        )
        await vm.load()

        await vm.commitVolume(-0.5, for: address)
        #expect(vm.preferences.staffVolumeOverrides[address] == 0)

        await vm.commitVolume(2.0, for: address)
        #expect(vm.preferences.staffVolumeOverrides[address] == 1)
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

    private func makeTwoStaffScore() -> Score {
        Score(
            division: 480,
            parts: [
                Part(
                    id: "P0",
                    instrument: Instrument(id: "x"),
                    staves: [
                        Staff(measures: [Measure(voices: [Voice(elements: [])])]),
                        Staff(measures: [Measure(voices: [Voice(elements: [])])]),
                    ]
                ),
            ],
            metaTags: [:]
        )
    }

    private func makeGateway(score: Score) -> FakeScoreFileGateway {
        FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "Test", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
        )))
    }

    @Test func setClefOverrideUpdatesPreferencesAndPersists() async throws {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        let score = makeTwoStaffScore()
        let gateway = makeGateway(score: score)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp")
        )
        await vm.load()
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        await vm.setClefOverride("G8vb", for: address)
        #expect(vm.preferences.staffClefOverrides == [address: "G8vb"])
        #expect(repo.savedReaderPreferences.last?.staffClefOverrides == [address: "G8vb"])
        #expect(vm.hasClefOverride(for: address))
    }

    @Test func clearClefOverrideRemovesEntry() async throws {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        let score = makeTwoStaffScore()
        let gateway = makeGateway(score: score)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp")
        )
        await vm.load()
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        await vm.setClefOverride("F", for: address)
        await vm.clearClefOverride(for: address)
        #expect(vm.preferences.staffClefOverrides.isEmpty)
        #expect(!vm.hasClefOverride(for: address))
    }

    @Test func effectiveClefReturnsOverrideThenAuthored() async throws {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        var score = makeTwoStaffScore()
        // Authored opening clef on staff (0,0) is "G" via an explicit
        // measure-0 clef element; on (0,1) is `nil` with defaultClefType "F".
        let openingClefVoice = Voice(elements: [.clef(Clef(concertClefType: "G"))])
        score.parts[0].staves[0].measures = [Measure(voices: [openingClefVoice])]
        score.parts[0].staves[1].defaultClefType = "F"
        let gateway = makeGateway(score: score)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp")
        )
        await vm.load()
        #expect(vm.effectiveClef(for: StaffAddress(partIndex: 0, staffIndexInPart: 0)) == "G")
        #expect(vm.effectiveClef(for: StaffAddress(partIndex: 0, staffIndexInPart: 1)) == "F")
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        await vm.setClefOverride("G8vb", for: address)
        #expect(vm.effectiveClef(for: address) == "G8vb")
    }
}

// swiftlint:enable file_length type_body_length
