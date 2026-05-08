import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@Suite @MainActor
struct ReaderViewModelHiddenStaffCursorTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "T", composer: nil, instrumentationSummary: nil,
            localFileName: "t.mscx", contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    /// Two-staff piano-shaped score. Both staves have the same shape:
    /// one measure, one voice, two quarter chords (each a single note).
    /// Division 480 → quarter = 480 ticks. Element index 1 sits at tick 480.
    private static func makePianoLikeScore() -> Score {
        func quarterChord(pitch: Int) -> VoiceElement {
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: pitch, tpc: 14)]
            ))
        }
        let voice = Voice(elements: [
            quarterChord(pitch: 60),
            quarterChord(pitch: 62),
        ])
        let staff = Staff(
            staffType: "stdNormal",
            group: "pitched",
            measures: [Measure(voices: [voice])]
        )
        let part = Part(
            id: "P0", trackName: "Piano",
            instrument: Instrument(id: "piano"),
            staves: [staff, staff]
        )
        return Score(division: 480, parts: [part], metaTags: [:])
    }

    private static func gateway(score: Score) -> FakeScoreFileGateway {
        FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "T", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
        )))
    }

    @Test func itemCursorOnVisibleStaffPassesThroughUnchanged() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: Self.gateway(score: Self.makePianoLikeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()
        vm.startObservingCursor()

        let visibleID = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0,
            elementIndex: 1, noteIndexInChord: 0
        )
        controller.emitCursor(.item(.note(visibleID)))
        #expect(vm.playbackCursor == .item(.note(visibleID)))
    }

    @Test func itemCursorOnHiddenStaffFallsBackToBeat() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: Self.gateway(score: Self.makePianoLikeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()
        vm.startObservingCursor()

        let hiddenStaff = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        await vm.toggleStaff(address: hiddenStaff)

        let hiddenID = NoteID(
            staff: hiddenStaff, measureIndex: 0, voiceIndex: 0,
            elementIndex: 1, noteIndexInChord: 0
        )
        controller.emitCursor(.item(.note(hiddenID)))
        #expect(vm.playbackCursor == .beat(measureIndex: 0, tickInMeasure: 480))
    }

    @Test func unhidingStaffRestoresItemCursorWithoutEngineEmit() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: Self.gateway(score: Self.makePianoLikeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()
        vm.startObservingCursor()

        let hiddenStaff = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        await vm.toggleStaff(address: hiddenStaff)
        let hiddenID = NoteID(
            staff: hiddenStaff, measureIndex: 0, voiceIndex: 0,
            elementIndex: 1, noteIndexInChord: 0
        )
        controller.emitCursor(.item(.note(hiddenID)))
        #expect(vm.playbackCursor == .beat(measureIndex: 0, tickInMeasure: 480))

        // Bring the staff back. Engine hasn't emitted anything new — the
        // cursor must recover to .item synthesized from the stored raw.
        await vm.toggleStaff(address: hiddenStaff)
        #expect(vm.playbackCursor == .item(.note(hiddenID)))
    }

    @Test func beatCursorPassesThroughEvenWithHiddenStaves() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: Self.gateway(score: Self.makePianoLikeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()
        vm.startObservingCursor()

        await vm.toggleStaff(
            address: StaffAddress(partIndex: 0, staffIndexInPart: 1)
        )
        let beat = ScoreCursor.beat(measureIndex: 0, tickInMeasure: 240)
        controller.emitCursor(beat)
        #expect(vm.playbackCursor == beat)
    }
}
