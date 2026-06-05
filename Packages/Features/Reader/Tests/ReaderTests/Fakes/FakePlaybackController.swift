import Domain
import Foundation
import SheetMusicCore

@MainActor
final class FakePlaybackController: PlaybackController {
    private(set) var loadCount = 0
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var lastLoadedPreferences: PlaybackPreferences?
    private(set) var lastLoadedDisplayTitle: String?
    private(set) var staffVolumes: [Int: Double] = [:]
    private(set) var staffSoloStates: [Int: Bool] = [:]
    private(set) var staffInstrumentCalls: [(staff: Int, bank: Int, program: Int)] = []
    private(set) var recordedSetCursorCalls: [ScoreCursor] = []
    private(set) var loopRangeCalls: [ABRepeatRange?] = []
    private(set) var tempoMultiplierCalls: [Double] = []
    private(set) var masterVolumeCalls: [Double] = []
    private(set) var metronomeEnabledCalls: [Bool] = []

    var loadError: Error?
    var playError: Error?
    var currentTimeSeconds: TimeInterval = 0
    var totalTimeSeconds: TimeInterval = 0
    private(set) var skipBySecondsCalls: [TimeInterval] = []

    func skip(bySeconds seconds: TimeInterval) {
        skipBySecondsCalls.append(seconds)
    }

    private var cursorHandler: ((ScoreCursor?) -> Void)?
    private var isPlayingHandler: ((Bool) -> Void)?

    init() {}

    func observeCursor(_ handler: @MainActor @escaping (ScoreCursor?) -> Void) {
        cursorHandler = handler
    }

    func observeIsPlaying(_ handler: @MainActor @escaping (Bool) -> Void) {
        isPlayingHandler = handler
    }

    /// Test helper — drives the registered handler synchronously.
    func emitIsPlaying(_ value: Bool) {
        isPlayingHandler?(value)
    }

    /// Test helper — drives the registered handler synchronously.
    func emitCursor(_ value: ScoreCursor?) {
        cursorHandler?(value)
    }

    func load(
        score _: Score, displayTitle: String?, preferences: PlaybackPreferences,
    ) throws {
        if let error = loadError { throw error }
        loadCount += 1
        lastLoadedPreferences = preferences
        lastLoadedDisplayTitle = displayTitle
    }

    func play() throws {
        if let error = playError { throw error }
        playCount += 1
    }

    func pause() {
        pauseCount += 1
    }

    private(set) var releaseEngineCount = 0

    func releaseEngine() {
        releaseEngineCount += 1
    }

    private(set) var reloadSoundfontCount = 0

    func reloadSoundfont() {
        reloadSoundfontCount += 1
    }

    func setStaffVolume(staff: Int, volume: Double) {
        staffVolumes[staff] = volume
    }

    func setCursor(to cursor: ScoreCursor) {
        recordedSetCursorCalls.append(cursor)
    }

    private(set) var recordedPreviewCalls: [(noteID: NoteID, duration: TimeInterval)] = []

    func playPreview(noteID: NoteID, duration: TimeInterval) {
        recordedPreviewCalls.append((noteID: noteID, duration: duration))
    }

    func setLoopRange(_ range: ABRepeatRange?) {
        loopRangeCalls.append(range)
    }

    func setMetronomeEnabled(_ enabled: Bool) {
        metronomeEnabledCalls.append(enabled)
    }

    func setTempoMultiplier(_ value: Double) {
        tempoMultiplierCalls.append(value)
    }

    func setMasterVolume(_ value: Double) {
        masterVolumeCalls.append(value)
    }

    func setStaffMute(staff _: Int, isMuted _: Bool) {}
    func setStaffSolo(staff: Int, isSolo: Bool) {
        staffSoloStates[staff] = isSolo
    }

    func setStaffInstrument(staff: Int, bank: Int, program: Int) {
        staffInstrumentCalls.append((staff: staff, bank: bank, program: program))
    }
}
