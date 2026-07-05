import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderViewModelPartProgramTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    private static func makeGateway(score: Score) -> FakeScoreFileGateway {
        FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "Test", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            ),
        )))
    }

    @Test func `set part program applies override to every staff under the part`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()],
                ),
                Part(
                    id: "P1", trackName: "Pno",
                    instrument: Instrument(id: "p", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(), Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()

        await vm.mixerModel.setPartProgram(6, forPartIndex: 1) // Harpsichord on the piano part

        let pianoTop = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        let pianoBottom = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        let violin = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        #expect(vm.mixerModel.effectiveProgram(forPartIndex: 1) == 6)
        #expect(vm.mixerModel.hasProgramOverride(forPartIndex: 1))
        #expect(vm.mixerModel.staffProgramOverrides[pianoTop] == 6)
        #expect(vm.mixerModel.staffProgramOverrides[pianoBottom] == 6)
        // The other part is untouched.
        #expect(vm.mixerModel.staffProgramOverrides[violin] == nil)
        #expect(!vm.mixerModel.hasProgramOverride(forPartIndex: 0))

        // Engine got one call per staff under the part, with flat indices 1 and 2.
        let pianoCalls = controller.staffInstrumentCalls.filter { $0.program == 6 }
        #expect(pianoCalls.count == 2)
        #expect(Set(pianoCalls.map(\.staff)) == [1, 2])
    }

    @Test func `part program override survives an app relaunch`() async {
        let item = Self.makeItem()
        // One repository stands in for the on-disk store across both "launches".
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()],
                ),
                Part(
                    id: "P1", trackName: "Pno",
                    instrument: Instrument(id: "p", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(), Staff()],
                ),
            ],
            metaTags: [:],
        )
        let pianoTop = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        let pianoBottom = StaffAddress(partIndex: 1, staffIndexInPart: 1)

        // Session 1: choose Harpsichord (program 6) for the piano part.
        let vm1 = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: FakePlaybackController(),
        )
        await vm1.load()
        await vm1.mixerModel.setPartProgram(6, forPartIndex: 1)

        // The choice was written through to persistence.
        #expect(repo.storedReaderPreferences[item.id]?.staffProgramOverrides[pianoTop] == 6)

        // Session 2 (app relaunch): a brand-new view model + mixer over the same store.
        let controller2 = FakePlaybackController()
        let vm2 = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller2,
        )
        await vm2.load()
        await vm2.playbackSession.prepareForPlayback()

        // The mixer shows the override again…
        #expect(vm2.mixerModel.effectiveProgram(forPartIndex: 1) == 6)
        #expect(vm2.mixerModel.hasProgramOverride(forPartIndex: 1))
        #expect(vm2.mixerModel.staffProgramOverrides[pianoTop] == 6)
        #expect(vm2.mixerModel.staffProgramOverrides[pianoBottom] == 6)

        // …and the engine is seeded with it on load, so playback actually uses it. Piano staves flatten
        // to indices 1 and 2 (violin takes 0).
        let seeded = controller2.lastLoadedPreferences?.perStaff ?? []
        #expect(seeded.first { $0.staffIndex == 1 }?.gmProgram == 6)
        #expect(seeded.first { $0.staffIndex == 2 }?.gmProgram == 6)
    }

    @Test func `clear part program override reverts every staff to score default`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Pno",
                    instrument: Instrument(id: "p", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(), Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()

        await vm.mixerModel.setPartProgram(6, forPartIndex: 0)
        await vm.mixerModel.clearPartProgramOverride(forPartIndex: 0)

        #expect(!vm.mixerModel.hasProgramOverride(forPartIndex: 0))
        #expect(vm.mixerModel.effectiveProgram(forPartIndex: 0) == 0)
        #expect(vm.mixerModel.staffProgramOverrides.isEmpty)
        // Last two engine calls reset both staves to the score default (0).
        let resetCalls = controller.staffInstrumentCalls.suffix(2)
        #expect(resetCalls.allSatisfy { $0.program == 0 })
        #expect(Set(resetCalls.map(\.staff)) == [0, 1])
    }
}
