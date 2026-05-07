import Domain
import Foundation
import SheetMusicCore

@MainActor
final class FakePlaybackController: PlaybackController {
    private(set) var loadCount = 0
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var lastLoadedPreferences: PlaybackPreferences?
    private(set) var staffVolumes: [Int: Double] = [:]
    private(set) var staffSoloStates: [Int: Bool] = [:]
    private(set) var staffInstrumentCalls: [(staff: Int, bank: Int, program: Int)] = []
    private(set) var recordedSetCursorCalls: [ScoreCursor] = []
    private(set) var tempoMultiplierCalls: [Double] = []
    private(set) var metronomeEnabledCalls: [Bool] = []

    var loadError: Error?
    var playError: Error?
    /// When true, `load` suspends until `Task.cancel()` fires, throwing
    /// `CancellationError`. Lets tests exercise the "loading" alert flow.
    var blocksLoadUntilCancelled: Bool = false
    /// What `areSoundfontsAvailableLocally` reports back. Defaults to
    /// `false` — the Reader treats that as "may need to fetch" and shows
    /// the alert, matching the existing tests' expectations.
    var soundfontsAvailableLocally: Bool = false

    private var cursorHandler: ((ScoreCursor?) -> Void)?

    init() {}

    func observeCursor(_ handler: @MainActor @escaping (ScoreCursor?) -> Void) {
        cursorHandler = handler
    }

    /// Test helper — drives the registered handler synchronously.
    func emitCursor(_ value: ScoreCursor?) {
        cursorHandler?(value)
    }

    func load(score _: Score, preferences: PlaybackPreferences) async throws {
        if blocksLoadUntilCancelled {
            try await Task.sleep(for: .seconds(60))
        }
        if let error = loadError { throw error }
        loadCount += 1
        lastLoadedPreferences = preferences
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
    var blocksPrefetchUntilCancelled: Bool = false
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

    func pause() { pauseCount += 1 }

    func setStaffVolume(staff: Int, volume: Double) {
        staffVolumes[staff] = volume
    }

    func setCursor(to cursor: ScoreCursor) {
        recordedSetCursorCalls.append(cursor)
    }

    func setLoopRange(_: ABRepeatRange?) {}
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
