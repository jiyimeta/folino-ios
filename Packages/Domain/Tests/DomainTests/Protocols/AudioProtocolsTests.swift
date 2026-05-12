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

    func areSoundfontsAvailableLocally(for _: Score) -> Bool {
        true
    }

    func isSoundfontCached(bank: Int, program: Int, isDrums: Bool) -> Bool {
        true
    }

    func prefetchSoundfont(bank: Int, program: Int, isDrums: Bool) throws {}

    func play() throws {}
    func pause() {}

    var currentTimeSeconds: TimeInterval = 0
    var totalTimeSeconds: TimeInterval = 0
    func skip(bySeconds _: TimeInterval) {}

    func setCursor(to cursor: ScoreCursor) {
        lastCursor = cursor
    }

    func setLoopRange(_ range: ABRepeatRange?) {}
    func setMetronomeEnabled(_ enabled: Bool) {}
    func setTempoMultiplier(_ value: Double) {
        lastTempo = value
    }

    func setStaffVolume(staff: Int, volume: Double) {}
    func setStaffMute(staff: Int, isMuted: Bool) {}
    func setStaffSolo(staff: Int, isSolo: Bool) {}
    func setStaffInstrument(staff: Int, bank: Int, program: Int) {}
}

private actor FakeSoundfontResolver: SoundfontResolver {
    var calls: [SoundfontPatchKey] = []
    var cache: [SoundfontPatch] = []

    func resolveSoundfont(bank: Int, program: Int, isDrums: Bool) throws -> URL {
        calls.append(SoundfontPatchKey(bank: bank, program: program, isDrums: isDrums))
        return URL(fileURLWithPath: "/tmp/fake.sf2")
    }

    func cachedPatches() throws -> [SoundfontPatch] {
        cache
    }

    func totalCacheSizeBytes() throws -> Int64 {
        cache.reduce(0) { $0 + $1.sizeBytes }
    }

    func deletePatch(bank: Int, program: Int, isDrums: Bool) throws {
        cache.removeAll { $0.bank == bank && $0.program == program }
    }

    func clearCache() throws {
        cache.removeAll()
    }
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

    @Test func `soundfont resolver records calls`() async throws {
        let resolver = FakeSoundfontResolver()
        _ = try await resolver.resolveSoundfont(bank: 0, program: 4, isDrums: false)
        _ = try await resolver.resolveSoundfont(bank: 128, program: 0, isDrums: true)
        let calls = await resolver.calls
        #expect(calls == [
            SoundfontPatchKey(bank: 0, program: 4, isDrums: false),
            SoundfontPatchKey(bank: 128, program: 0, isDrums: true),
        ])
    }
}
