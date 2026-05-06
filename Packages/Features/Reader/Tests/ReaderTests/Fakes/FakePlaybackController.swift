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
    private(set) var recordedSetCursorCalls: [ScoreCursor] = []

    var loadError: Error?
    var playError: Error?
    /// When true, `load` suspends until `Task.cancel()` fires, throwing
    /// `CancellationError`. Lets tests exercise the "loading" alert flow.
    var blocksLoadUntilCancelled: Bool = false

    let cursorContinuation: AsyncStream<ScoreCursor?>.Continuation
    nonisolated let cursor: AsyncStream<ScoreCursor?>

    init() {
        var c: AsyncStream<ScoreCursor?>.Continuation!
        cursor = AsyncStream { c = $0 }
        cursorContinuation = c
    }

    func load(score _: Score, preferences: PlaybackPreferences) async throws {
        if blocksLoadUntilCancelled {
            try await Task.sleep(for: .seconds(60))
        }
        if let error = loadError { throw error }
        loadCount += 1
        lastLoadedPreferences = preferences
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
    func setMetronomeEnabled(_: Bool) {}
    func setTempoMultiplier(_: Double) {}
    func setStaffMute(staff _: Int, isMuted _: Bool) {}
    func setStaffSolo(staff: Int, isSolo: Bool) {
        staffSoloStates[staff] = isSolo
    }

    func setStaffInstrument(staff _: Int, bank _: Int, program _: Int) {}
}
