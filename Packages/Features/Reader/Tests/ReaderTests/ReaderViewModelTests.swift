import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderViewModelTests {
    /// The single-instrument fixture score's one mixer strip.
    private static let strip = MixerStripID(partIndex: 0, instrumentOrdinal: 0)

    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    @Test func `successful load transitions to loaded and updates last opened`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let gateway = FakeScoreFileGateway()
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp"),
        )

        await vm.load()
        if case .loaded = vm.loadState {} else {
            Issue.record("expected .loaded, got \(vm.loadState)")
        }
        #expect(repo.savedScoreItems.count == 1)
        #expect(repo.savedScoreItems.first?.lastOpenedAt != nil)
    }

    @Test func `load failure transitions to failed and does not save`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let gateway = FakeScoreFileGateway(
            loadScoreResult: .failure(.scoreFileNotFound(name: "test.mscx")),
        )
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp"),
        )

        await vm.load()
        if case .failed = vm.loadState {} else {
            Issue.record("expected .failed, got \(vm.loadState)")
        }
        #expect(repo.savedScoreItems.isEmpty)
    }

    @Test func `reload after failure succeeds`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let gateway = FakeScoreFileGateway(
            loadScoreResult: .failure(.scoreParseFailed(reason: "bad")),
        )
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp"),
        )
        await vm.load()
        if case .failed = vm.loadState {} else {
            Issue.record("expected initial failure")
        }

        gateway.loadScoreResult = .success((
            score: Score(division: 480, parts: [], metaTags: [:]),
            summary: ScoreFileSummary(
                title: "Test", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            ),
        ))
        await vm.load()
        if case .loaded = vm.loadState {} else {
            Issue.record("expected .loaded after retry, got \(vm.loadState)")
        }
    }

    @Test func `first open resolves the device class default without persisting`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let gateway = FakeScoreFileGateway()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 11, // simulates iPhone compact
        )

        await vm.load()
        // The user never chose a staff size, so the slice stays untouched and only the effective read resolves it.
        #expect(vm.layoutModel.staffSize == nil)
        #expect(vm.layoutModel.effectiveStaffSize == 11)
        #expect(vm.layoutModel.hiddenStaves.isEmpty)
        // The fixture score authors nothing hidden, so the seed carries no information and is not written. A row that
        // says only "defaults" would make every opened score look touched.
        #expect(repo.savedReaderPreferences.isEmpty)
    }

    @Test func `load uses persisted preferences when present`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let hidden: Set<StaffAddress> = [StaffAddress(partIndex: 1, staffIndexInPart: 0)]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 18, hiddenStaves: hidden,
        )
        let gateway = FakeScoreFileGateway()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14,
        )

        await vm.load()
        #expect(vm.layoutModel.staffSize == 18)
        #expect(vm.layoutModel.hiddenStaves == hidden)
        // No new save because the persisted record is reused as-is.
        #expect(repo.savedReaderPreferences.isEmpty)
    }

    @Test func `increment and decrement staff size persist`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 14, hiddenStaves: [],
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14,
        )
        await vm.load()
        await vm.layoutModel.incrementStaffSize()
        #expect(vm.layoutModel.staffSize == 15)
        await vm.layoutModel.decrementStaffSize()
        await vm.layoutModel.decrementStaffSize()
        #expect(vm.layoutModel.staffSize == 13)
        // 1 save from each mutator.
        #expect(repo.savedReaderPreferences.count == 3)
    }

    @Test func `staff size is clamped to min and max`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 8, hiddenStaves: [],
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14,
        )
        await vm.load()
        await vm.layoutModel.decrementStaffSize()
        #expect(vm.layoutModel.staffSize == 8) // already at min, stays at min
        for _ in 0 ..< 25 {
            await vm.layoutModel.incrementStaffSize()
        }
        #expect(vm.layoutModel.staffSize == 28) // capped
    }

    @Test func `toggle staff flips membership`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 14, hiddenStaves: [],
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14,
        )
        await vm.load()
        let address = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        await vm.layoutModel.toggleStaff(address)
        #expect(vm.layoutModel.hiddenStaves == [address])
        await vm.layoutModel.toggleStaff(address)
        #expect(vm.layoutModel.hiddenStaves.isEmpty)
    }

    @Test func `volume falls back to one when the engine has no strips`() {
        let vm = makeVMNoLoad()
        #expect(vm.mixerModel.volume(for: Self.strip) == 1.0)
    }

    @Test func `set volume clamps out of range values`() {
        let vm = makeVMNoLoad()

        vm.mixerModel.setVolume(-0.5, for: Self.strip)
        #expect(vm.mixerModel.liveVolumes[Self.strip] == 0)

        vm.mixerModel.setVolume(2.0, for: Self.strip)
        #expect(vm.mixerModel.liveVolumes[Self.strip] == 1)
    }

    @Test func `volume uses the engine's strip level when no override`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 64)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        // What the engine reports for the score's CC 7 of 64.
        controller.strips = [
            MixerStrip(
                id: Self.strip, partName: "Vn", instrumentName: "Vn",
                defaultVolume: 64.0 / 127.0, defaultProgram: 40, isDrums: false,
            ),
        ]
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(loadScoreResult: .success((
                score: score,
                summary: ScoreFileSummary(
                    title: "T", composer: nil, instrumentationSummary: "",
                    lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
                ),
            ))),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14,
            playbackController: controller,
        )
        await vm.load()
        await vm.playbackSession.prepareForPlayback()
        let value = vm.mixerModel.volume(for: Self.strip)
        #expect(abs(value - 64.0 / 127.0) < 0.0001)
    }

    @Test func `volume uses persisted override when present`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id,
            staffSize: 14,
            hiddenStaves: [],
            stripVolumeOverrides: [Self.strip: 0.3],
        )
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 100)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(loadScoreResult: .success((
                score: score,
                summary: ScoreFileSummary(
                    title: "T", composer: nil, instrumentationSummary: "",
                    lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
                ),
            ))),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14,
        )
        await vm.load()
        #expect(vm.mixerModel.volume(for: Self.strip) == 0.3)
    }

    @Test func `reset zoom returns to unit`() {
        let vm = makeVMNoLoad()
        vm.viewportZoom = 2.5
        vm.resetZoom()
        #expect(vm.viewportZoom == 1.0)
    }

    @Test func `playback inspector is toggleable`() {
        let vm = makeVMNoLoad()
        #expect(!vm.isPlaybackInspectorPresented)
        vm.isPlaybackInspectorPresented = true
        #expect(vm.isPlaybackInspectorPresented)
    }

    @Test func `visual inspector is toggleable`() {
        let vm = makeVMNoLoad()
        #expect(!vm.isVisualInspectorPresented)
        vm.isVisualInspectorPresented = true
        #expect(vm.isVisualInspectorPresented)
    }

    @Test func `set honor layout breaks persists and updates preferences`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 14, hiddenStaves: [],
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14,
            defaultHonorLayoutBreaks: true,
        )
        await vm.load()
        // Untouched: nothing stored, so it reads as the default without being marked as a user choice.
        #expect(vm.layoutModel.honorLayoutBreaks == nil)
        #expect(vm.layoutModel.effectiveHonorLayoutBreaks == true)

        await vm.layoutModel.setHonorLayoutBreaks(false)
        #expect(vm.layoutModel.honorLayoutBreaks == false)
        #expect(repo.savedReaderPreferences.last?.honorLayoutBreaks == false)

        await vm.layoutModel.setHonorLayoutBreaks(true)
        #expect(vm.layoutModel.honorLayoutBreaks == true)
        #expect(repo.savedReaderPreferences.last?.honorLayoutBreaks == true)
    }

    @Test func `set volume updates live dict without persisting`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 100)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(loadScoreResult: .success((
                score: score,
                summary: ScoreFileSummary(
                    title: "T", composer: nil, instrumentationSummary: "",
                    lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
                ),
            ))),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14,
        )
        await vm.load()
        let savesBefore = repo.savedReaderPreferences.count

        vm.mixerModel.setVolume(0.4, for: Self.strip)

        #expect(vm.mixerModel.liveVolumes[Self.strip] == 0.4)
        #expect(vm.mixerModel.volume(for: Self.strip) == 0.4)
        #expect(vm.mixerModel.volumeOverrides[Self.strip] == nil)
        #expect(repo.savedReaderPreferences.count == savesBefore)
    }

    @Test func `commit volume persists override and clears live value`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 100)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(loadScoreResult: .success((
                score: score,
                summary: ScoreFileSummary(
                    title: "T", composer: nil, instrumentationSummary: "",
                    lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
                ),
            ))),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14,
        )
        await vm.load()
        vm.mixerModel.setVolume(0.4, for: Self.strip)
        let savesBefore = repo.savedReaderPreferences.count

        await vm.mixerModel.commitVolume(0.4, for: Self.strip)

        #expect(vm.mixerModel.volumeOverrides[Self.strip] == 0.4)
        #expect(vm.mixerModel.liveVolumes[Self.strip] == nil)
        #expect(vm.mixerModel.volume(for: Self.strip) == 0.4)
        #expect(repo.savedReaderPreferences.count == savesBefore + 1)
    }

    @Test func `commit volume clamps out of range values`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v"), staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(loadScoreResult: .success((
                score: score,
                summary: ScoreFileSummary(
                    title: "T", composer: nil, instrumentationSummary: "",
                    lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
                ),
            ))),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14,
        )
        await vm.load()

        await vm.mixerModel.commitVolume(-0.5, for: Self.strip)
        #expect(vm.mixerModel.volumeOverrides[Self.strip] == 0)

        await vm.mixerModel.commitVolume(2.0, for: Self.strip)
        #expect(vm.mixerModel.volumeOverrides[Self.strip] == 1)
    }

    private func makeVMNoLoad() -> ReaderViewModel {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        return ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14,
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
                    ],
                ),
            ],
            metaTags: [:],
        )
    }

    private func makeGateway(score: Score) -> FakeScoreFileGateway {
        FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "Test", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            ),
        )))
    }

    @Test func `set clef override updates preferences and persists`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        let score = makeTwoStaffScore()
        let gateway = makeGateway(score: score)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp"),
        )
        await vm.load()
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        await vm.layoutModel.setClefOverride("G8vb", for: address)
        #expect(vm.layoutModel.staffClefOverrides == [address: "G8vb"])
        #expect(repo.savedReaderPreferences.last?.staffClefOverrides == [address: "G8vb"])
        #expect(vm.layoutModel.hasClefOverride(for: address))
    }

    @Test func `clear clef override removes entry`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        let score = makeTwoStaffScore()
        let gateway = makeGateway(score: score)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp"),
        )
        await vm.load()
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        await vm.layoutModel.setClefOverride("F", for: address)
        await vm.layoutModel.clearClefOverride(for: address)
        #expect(vm.layoutModel.staffClefOverrides.isEmpty)
        #expect(!vm.layoutModel.hasClefOverride(for: address))
    }

    @Test func `effective clef returns override then authored`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        var score = makeTwoStaffScore()
        // Authored opening clef on staff (0,0) is "G" via an explicit measure-0 clef element; on (0,1) is `nil` with
        // defaultClefType "F".
        let openingClefVoice = Voice(elements: [.clef(Clef(concertClefType: "G"))])
        score.parts[0].staves[0].measures = [Measure(voices: [openingClefVoice])]
        score.parts[0].staves[1].defaultClefType = "F"
        let gateway = makeGateway(score: score)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp"),
        )
        await vm.load()
        #expect(vm.layoutModel.effectiveClef(for: StaffAddress(partIndex: 0, staffIndexInPart: 0)) == "G")
        #expect(vm.layoutModel.effectiveClef(for: StaffAddress(partIndex: 0, staffIndexInPart: 1)) == "F")
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        await vm.layoutModel.setClefOverride("G8vb", for: address)
        #expect(vm.layoutModel.effectiveClef(for: address) == "G8vb")
    }
}
