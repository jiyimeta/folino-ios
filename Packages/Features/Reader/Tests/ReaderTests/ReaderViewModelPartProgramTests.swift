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

        await vm.setPartProgram(6, forPartIndex: 1) // Harpsichord on the piano part

        let pianoTop = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        let pianoBottom = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        let violin = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        #expect(vm.effectiveProgram(forPartIndex: 1) == 6)
        #expect(vm.hasProgramOverride(forPartIndex: 1))
        #expect(vm.preferences.staffProgramOverrides[pianoTop] == 6)
        #expect(vm.preferences.staffProgramOverrides[pianoBottom] == 6)
        // The other part is untouched.
        #expect(vm.preferences.staffProgramOverrides[violin] == nil)
        #expect(!vm.hasProgramOverride(forPartIndex: 0))

        // Engine got one call per staff under the part, with flat indices 1 and 2.
        let pianoCalls = controller.staffInstrumentCalls.filter { $0.program == 6 }
        #expect(pianoCalls.count == 2)
        #expect(Set(pianoCalls.map(\.staff)) == [1, 2])
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

        await vm.setPartProgram(6, forPartIndex: 0)
        await vm.clearPartProgramOverride(forPartIndex: 0)

        #expect(!vm.hasProgramOverride(forPartIndex: 0))
        #expect(vm.effectiveProgram(forPartIndex: 0) == 0)
        #expect(vm.preferences.staffProgramOverrides.isEmpty)
        // Last two engine calls reset both staves to the score default (0).
        let resetCalls = controller.staffInstrumentCalls.suffix(2)
        #expect(resetCalls.allSatisfy { $0.program == 0 })
        #expect(Set(resetCalls.map(\.staff)) == [0, 1])
    }
}
