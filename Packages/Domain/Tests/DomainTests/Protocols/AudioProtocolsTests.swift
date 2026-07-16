@testable import Domain
import Foundation
import Testing

@MainActor
private final class FakePlaybackController: PlaybackController {
    var loadedScores = 0
    var lastTempo = 1.0
    var lastCursor: ScoreCursor?
    private var cursorHandler: ((ScoreCursor?) -> Void)?

    func observeCursor(_ handler: @MainActor @escaping (ScoreCursor?) -> Void) {
        cursorHandler = handler
    }

    func observeIsPlaying(_: @MainActor @escaping (Bool) -> Void) {}

    func load(
        score: Score, displayTitle _: String?, preferences: PlaybackPreferences,
    ) throws {
        loadedScores += 1
    }

    func play(countIn _: Bool) throws {}
    func pause() {}
    func releaseEngine() {}
    func reloadSoundfont() {}

    var currentTimeSeconds: TimeInterval = 0
    var totalTimeSeconds: TimeInterval = 0
    func skip(bySeconds _: TimeInterval) {}

    func setCursor(to cursor: ScoreCursor) {
        lastCursor = cursor
    }

    func playPreview(noteID: NoteID, duration: TimeInterval) {}

    private(set) var scorePreviewCalls: [(noteID: NoteID, duration: TimeInterval)] = []
    func playPreview(noteID: NoteID, in _: Score, duration: TimeInterval) {
        scorePreviewCalls.append((noteID, duration))
    }

    func setLoopRange(_ range: ABRepeatRange?) {}
    func setMetronomeEnabled(_ enabled: Bool) {}
    func setTempoMultiplier(_ value: Double) {
        lastTempo = value
    }

    func setTranspose(semitones _: Int) {}

    func setMasterVolume(_ value: Double) {}
    func setMasterTuning(cents _: Double) {}

    func setStaffVolume(staff: Int, volume: Double) {}
    func setStaffMute(staff: Int, isMuted: Bool) {}
    func setStaffSolo(staff: Int, isSolo: Bool) {}
    func setStaffInstrument(staff: Int, bank: Int, program: Int) {}
}

struct AudioProtocolsTests {
    @MainActor @Test func `playback controller sets cursor and tempo`() async {
        let controller = FakePlaybackController()
        let target = ScoreCursor.beat(measureIndex: 2, tickInMeasure: 240)
        await controller.setCursor(to: target)
        await controller.setTempoMultiplier(0.75)
        #expect(controller.lastCursor == target)
        #expect(controller.lastTempo == 0.75)
    }

    @MainActor @Test func `playback controller previews a note against a caller-supplied score`() async {
        let controller = FakePlaybackController()
        let noteID = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
        )
        await controller.playPreview(noteID: noteID, in: Score(division: 480), duration: 0.3)
        #expect(controller.scorePreviewCalls.count == 1)
    }
}
