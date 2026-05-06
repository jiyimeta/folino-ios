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

    var loadError: Error?
    var playError: Error?

    private let cursorContinuation: AsyncStream<ChordPath?>.Continuation
    nonisolated let cursor: AsyncStream<ChordPath?>

    init() {
        var c: AsyncStream<ChordPath?>.Continuation!
        cursor = AsyncStream { c = $0 }
        cursorContinuation = c
    }

    func load(score _: Score, preferences: PlaybackPreferences) throws {
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

    func setCursor(to _: ChordPath) {}
    func setLoopRange(_: ABRepeatRange?) {}
    func setMetronomeEnabled(_: Bool) {}
    func setTempoMultiplier(_: Double) {}
    func setStaffMute(staff _: Int, isMuted _: Bool) {}
    func setStaffSolo(staff _: Int, isSolo _: Bool) {}
    func setStaffInstrument(staff _: Int, bank _: Int, program _: Int) {}
}
