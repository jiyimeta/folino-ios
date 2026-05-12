import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderViewModelHiddenStaffCursorTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "T", composer: nil, instrumentationSummary: nil,
            localFileName: "t.mscx", contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    /// Two-staff piano-shaped score. Both staves have the same shape:
    /// one measure, one voice, two quarter chords (each a single note).
    /// Division 480 → quarter = 480 ticks. Element index 1 sits at tick 480.
    private static func makePianoLikeScore() -> Score {
        func quarterChord(pitch: Int) -> VoiceElement {
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: pitch, tpc: 14)],
            ))
        }
        let voice = Voice(elements: [
            quarterChord(pitch: 60),
            quarterChord(pitch: 62),
        ])
        let staff = Staff(
            staffType: "stdNormal",
            group: "pitched",
            measures: [Measure(voices: [voice])],
        )
        let part = Part(
            id: "P0", trackName: "Piano",
            instrument: Instrument(id: "piano"),
            staves: [staff, staff],
        )
        return Score(division: 480, parts: [part], metaTags: [:])
    }

    private static func gateway(score: Score) -> FakeScoreFileGateway {
        FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "T", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            ),
        )))
    }

    @Test func `item cursor on visible staff passes through unchanged`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: Self.gateway(score: Self.makePianoLikeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()
        vm.startObservingCursor()

        let visibleID = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0,
            elementIndex: 1, noteIndexInChord: 0,
        )
        controller.emitCursor(.item(.note(visibleID)))
        #expect(vm.playbackCursor == .item(.note(visibleID)))
    }

    @Test func `item cursor on hidden staff falls back to beat`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: Self.gateway(score: Self.makePianoLikeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()
        vm.startObservingCursor()

        let hiddenStaff = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        await vm.layoutModel.toggleStaff(hiddenStaff)

        let hiddenID = NoteID(
            staff: hiddenStaff, measureIndex: 0, voiceIndex: 0,
            elementIndex: 1, noteIndexInChord: 0,
        )
        controller.emitCursor(.item(.note(hiddenID)))
        #expect(vm.playbackCursor == .beat(measureIndex: 0, tickInMeasure: 480))
    }

    /// Engine-side cursor on a visible staff whose full-score address
    /// differs from its filtered address (i.e. an earlier staff in the
    /// same part is hidden). The `LayoutDocument` is built from the
    /// filtered score, so its `NoteID`s carry filtered staff addresses.
    /// If the cursor isn't re-stamped to the filtered address,
    /// `PlaybackCursorView.itemFrame` fails to match any layout entry
    /// and the cursor visually disappears during playback.
    @Test func `engine cursor on visible staff re-stamps to filtered address when earlier staff is hidden`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: Self.gateway(score: Self.makePianoLikeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()
        vm.startObservingCursor()

        // Hide the FIRST staff so the visible staff's full address
        // (0, 1) disagrees with its filtered address (0, 0).
        let hiddenStaff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        await vm.layoutModel.toggleStaff(hiddenStaff)

        // Engine emits the visible staff's note using its full address.
        let fullID = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 1),
            measureIndex: 0, voiceIndex: 0,
            elementIndex: 1, noteIndexInChord: 0,
        )
        controller.emitCursor(.item(.note(fullID)))

        let filteredID = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0,
            elementIndex: 1, noteIndexInChord: 0,
        )
        #expect(vm.playbackCursor == .item(.note(filteredID)))
    }

    @Test func `unhiding staff restores item cursor without engine emit`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: Self.gateway(score: Self.makePianoLikeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()
        vm.startObservingCursor()

        let hiddenStaff = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        await vm.layoutModel.toggleStaff(hiddenStaff)
        let hiddenID = NoteID(
            staff: hiddenStaff, measureIndex: 0, voiceIndex: 0,
            elementIndex: 1, noteIndexInChord: 0,
        )
        controller.emitCursor(.item(.note(hiddenID)))
        #expect(vm.playbackCursor == .beat(measureIndex: 0, tickInMeasure: 480))

        // Bring the staff back. Engine hasn't emitted anything new — the
        // cursor must recover to .item synthesized from the stored raw.
        await vm.layoutModel.toggleStaff(hiddenStaff)
        #expect(vm.playbackCursor == .item(.note(hiddenID)))
    }

    /// Tap-to-seek path: `nearestCursor` returns IDs addressed against
    /// the *filtered* score (because `LayoutDocument` was built from it).
    /// `StaffAddress` is purely positional, so when the FIRST staff is
    /// hidden the visible staff renders at filtered address `(0, 0)` but
    /// its full-score address is `(0, 1)` — the address the playback
    /// engine's timeline is keyed by. Without translation the engine
    /// can't resolve the cursor (most visibly when the visible staff
    /// holds a whole rest and the hidden staff holds notes: the `.rest`
    /// key bucket collides with the hidden staff's `.note` entries and
    /// the seek silently no-ops). Verify the controller receives the
    /// full-score address.
    @Test func `manual cursor translates filtered staff address to full score`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: Self.gateway(score: Self.makePianoLikeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()

        // Hide the FIRST staff so the visible staff's filtered address
        // (0, 0) disagrees with its full-score address (0, 1).
        let hiddenStaff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        await vm.layoutModel.toggleStaff(hiddenStaff)

        // What `nearestCursor` would produce after a tap on the visible
        // staff: filtered address (0, 0).
        let filteredNote = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0,
            elementIndex: 1, noteIndexInChord: 0,
        )
        vm.setManualCursor(.item(.note(filteredNote)))
        for _ in 0 ..< 5 {
            await Task.yield()
        }

        let fullNote = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 1),
            measureIndex: 0, voiceIndex: 0,
            elementIndex: 1, noteIndexInChord: 0,
        )
        #expect(controller.recordedSetCursorCalls == [.item(.note(fullNote))])
    }

    /// Whole-rest variant of the translation test — this is the case the
    /// user reported (visible staff = whole rest, hidden staff = notes).
    @Test func `manual cursor translates rest ID staff address to full score`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: Self.gateway(score: Self.makePianoLikeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()
        let hiddenStaff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        await vm.layoutModel.toggleStaff(hiddenStaff)

        let filteredRest = RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
        vm.setManualCursor(.item(.rest(filteredRest)))
        for _ in 0 ..< 5 {
            await Task.yield()
        }

        let fullRest = RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 1),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
        #expect(controller.recordedSetCursorCalls == [.item(.rest(fullRest))])
    }

    /// No translation when nothing is hidden — the cursor's filtered
    /// address already matches the full-score address.
    @Test func `manual cursor passes through when nothing hidden`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: Self.gateway(score: Self.makePianoLikeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()

        let note = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 1),
            measureIndex: 0, voiceIndex: 0,
            elementIndex: 0, noteIndexInChord: 0,
        )
        vm.setManualCursor(.item(.note(note)))
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(controller.recordedSetCursorCalls == [.item(.note(note))])
    }

    @Test func `beat cursor passes through even with hidden staves`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: Self.gateway(score: Self.makePianoLikeScore()),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()
        vm.startObservingCursor()

        await vm.layoutModel.toggleStaff(
            StaffAddress(partIndex: 0, staffIndexInPart: 1),
        )
        let beat = ScoreCursor.beat(measureIndex: 0, tickInMeasure: 240)
        controller.emitCursor(beat)
        #expect(vm.playbackCursor == beat)
    }
}
