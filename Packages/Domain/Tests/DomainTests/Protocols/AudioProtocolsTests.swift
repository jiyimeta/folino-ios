@testable import Domain
import Foundation
import Testing

private final class FakePlaybackController: PlaybackController, @unchecked Sendable {
    var loadedScores = 0
    var lastTempo: Double = 1.0
    var lastCursor: ChordPath?
    let cursorContinuation: AsyncStream<ScoreCursor?>.Continuation
    let cursor: AsyncStream<ScoreCursor?>

    init() {
        var c: AsyncStream<ScoreCursor?>.Continuation!
        cursor = AsyncStream { c = $0 }
        cursorContinuation = c
    }

    func load(score: Score, preferences: PlaybackPreferences) throws {
        loadedScores += 1
    }

    func play() throws {}
    func pause() {}
    func setCursor(to chord: ChordPath) { lastCursor = chord }
    func setLoopRange(_ range: ABRepeatRange?) {}
    func setMetronomeEnabled(_ enabled: Bool) {}
    func setTempoMultiplier(_ value: Double) { lastTempo = value }
    func setStaffVolume(staff: Int, volume: Double) {}
    func setStaffMute(staff: Int, isMuted: Bool) {}
    func setStaffSolo(staff: Int, isSolo: Bool) {}
    func setStaffInstrument(staff: Int, bank: Int, program: Int) {}
}

private actor FakeSoundfontResolver: SoundfontResolver {
    var calls: [SoundfontPatchKey] = []
    var cache: [SoundfontPatch] = []

    func resolveSoundfont(bank: Int, program: Int) throws -> URL {
        calls.append(SoundfontPatchKey(bank: bank, program: program))
        return URL(fileURLWithPath: "/tmp/fake.sf2")
    }

    func cachedPatches() throws -> [SoundfontPatch] { cache }
    func totalCacheSizeBytes() throws -> Int64 { cache.reduce(0) { $0 + $1.sizeBytes } }
    func deletePatch(bank: Int, program: Int) throws {
        cache.removeAll { $0.bank == bank && $0.program == program }
    }

    func clearCache() throws { cache.removeAll() }
}

@Suite struct AudioProtocolsTests {
    @Test func playbackControllerSetsCursorAndTempo() async throws {
        let controller = FakePlaybackController()
        await controller.setCursor(to: ChordPath(systemIndex: 1, measureIndex: 2, voiceIndex: 0, chordIndex: 3))
        await controller.setTempoMultiplier(0.75)
        #expect(controller.lastCursor == ChordPath(systemIndex: 1, measureIndex: 2, voiceIndex: 0, chordIndex: 3))
        #expect(controller.lastTempo == 0.75)
    }

    @Test func soundfontResolverRecordsCalls() async throws {
        let resolver = FakeSoundfontResolver()
        _ = try await resolver.resolveSoundfont(bank: 0, program: 4)
        _ = try await resolver.resolveSoundfont(bank: 128, program: 0)
        let calls = await resolver.calls
        #expect(calls == [SoundfontPatchKey(bank: 0, program: 4), SoundfontPatchKey(bank: 128, program: 0)])
    }
}
