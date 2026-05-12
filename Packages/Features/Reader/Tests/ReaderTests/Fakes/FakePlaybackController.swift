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
    private(set) var metronomeEnabledCalls: [Bool] = []

    var loadError: Error?
    var playError: Error?
    /// When true, `load` suspends until `Task.cancel()` fires, throwing
    /// `CancellationError`. Lets tests exercise the "loading" alert flow.
    var blocksLoadUntilCancelled = false
    /// What `areSoundfontsAvailableLocally` reports back. Defaults to
    /// `false` — the Reader treats that as "may need to fetch" and shows
    /// the alert, matching the existing tests' expectations.
    var soundfontsAvailableLocally = false
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
    ) async throws {
        if blocksLoadUntilCancelled {
            try await Task.sleep(for: .seconds(60))
        }
        if let error = loadError { throw error }
        loadCount += 1
        lastLoadedPreferences = preferences
        lastLoadedDisplayTitle = displayTitle
    }

    func areSoundfontsAvailableLocally(for _: Score) -> Bool {
        soundfontsAvailableLocally
    }

    /// Patches the fake reports as already on disk. Default: empty —
    /// every pick is a cache miss unless the test seeds this set.
    var cachedPatches: Set<SoundfontPatchKey> = []
    private(set) var prefetchedPatches: [SoundfontPatchKey] = []
    /// When true, `prefetchSoundfont` suspends until `Task.cancel()`
    /// fires, throwing `CancellationError`. Mirrors
    /// `blocksLoadUntilCancelled` for the per-patch path.
    var blocksPrefetchUntilCancelled = false
    var prefetchError: Error?

    func isSoundfontCached(bank: Int, program: Int, isDrums: Bool) -> Bool {
        cachedPatches.contains(SoundfontPatchKey(bank: bank, program: program, isDrums: isDrums))
    }

    func prefetchSoundfont(bank: Int, program: Int, isDrums: Bool) async throws {
        if blocksPrefetchUntilCancelled {
            try await Task.sleep(for: .seconds(60))
        }
        if let error = prefetchError { throw error }
        let key = SoundfontPatchKey(bank: bank, program: program, isDrums: isDrums)
        prefetchedPatches.append(key)
        cachedPatches.insert(key)
    }

    func play() throws {
        if let error = playError { throw error }
        playCount += 1
    }

    func pause() {
        pauseCount += 1
    }

    func setStaffVolume(staff: Int, volume: Double) {
        staffVolumes[staff] = volume
    }

    func setCursor(to cursor: ScoreCursor) {
        recordedSetCursorCalls.append(cursor)
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

    func setStaffMute(staff _: Int, isMuted _: Bool) {}
    func setStaffSolo(staff: Int, isSolo: Bool) {
        staffSoloStates[staff] = isSolo
    }

    func setStaffInstrument(staff: Int, bank: Int, program: Int) {
        staffInstrumentCalls.append((staff: staff, bank: bank, program: program))
    }
}
