import Combine
import Domain
import Foundation
import SheetMusicAudio
import SheetMusicCore

/// Bridges Folino's `Domain.PlaybackController` onto
/// `SheetMusicAudio.PlaybackEngine`. The engine is `@MainActor` so this
/// adapter is too — the protocol's `async` methods become hops onto the
/// main actor.
///
/// MVP scope: load → play / pause and per-staff volume forwarding. Cursor
/// streaming, A–B repeat, tempo multiplier, mute / solo / instrument
/// changes are stubbed pending UI demand.
@MainActor
public final class LivePlaybackController: Domain.PlaybackController {
    private let engine: PlaybackEngine
    private let domainResolver: (any Domain.SoundfontResolver)?
    private var loadedScore: Score?

    private let cursorContinuation: AsyncStream<ScoreCursor?>.Continuation
    public nonisolated let cursor: AsyncStream<ScoreCursor?>
    private var cancellables: Set<AnyCancellable> = []

    public init(
        soundfontResolver: any SheetMusicAudio.SoundfontResolver,
        domainResolver: (any Domain.SoundfontResolver)? = nil
    ) {
        engine = PlaybackEngine(soundfontResolver: soundfontResolver)
        self.domainResolver = domainResolver
        var continuation: AsyncStream<ScoreCursor?>.Continuation!
        cursor = AsyncStream { continuation = $0 }
        cursorContinuation = continuation
        engine.$currentCursor
            .sink { [continuation] value in
                continuation.yield(value)
            }
            .store(in: &cancellables)
    }

    public func load(score: Score, preferences: PlaybackPreferences) async throws {
        if let domainResolver {
            await Self.prefetchSoundfonts(score: score, resolver: domainResolver)
        }
        // Prefetch's URLSession calls honor cancellation but the TaskGroup
        // returns regardless. Bail before the engine prepare so a cancel
        // mid-load doesn't end up with a primed engine the user expects to
        // be silent.
        try Task.checkCancellation()
        try engine.prepare(score: score)
        loadedScore = score
        for state in preferences.perStaff {
            engine.setVolume(
                forChannel: .staff(state.staffIndex), to: Float(state.volume)
            )
            engine.setMuted(
                forChannel: .staff(state.staffIndex), to: state.isMuted
            )
            engine.setSoloed(
                forChannel: .staff(state.staffIndex), to: state.isSolo
            )
        }
    }

    /// Walks the score's distinct `(bank, program)` pairs and asks the
    /// resolver to materialise each on disk, in parallel. Soft-fails per
    /// patch — if one download 404s, the others still land and the engine
    /// just plays that voice silently.
    private static func prefetchSoundfonts(
        score: Score, resolver: any Domain.SoundfontResolver
    ) async {
        var seen: Set<SoundfontPatchKey> = []
        var pairs: [(bank: Int, program: Int)] = []
        for entry in score.allStaves {
            guard let part = score.part(at: entry.address) else { continue }
            let channel = part.instrument.channels.first ?? InstrumentChannel()
            let key = SoundfontPatchKey(bank: channel.bank, program: channel.program)
            if seen.insert(key).inserted {
                pairs.append((channel.bank, channel.program))
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for (bank, program) in pairs {
                group.addTask {
                    _ = try? await resolver.resolveSoundfont(bank: bank, program: program)
                }
            }
        }
    }

    public func play() throws {
        guard let score = loadedScore else { return }
        engine.play(in: score)
    }

    public func pause() {
        engine.pause()
    }

    public func setStaffVolume(staff: Int, volume: Double) {
        engine.setVolume(forChannel: .staff(staff), to: Float(volume))
    }

    public func setStaffMute(staff: Int, isMuted: Bool) {
        engine.setMuted(forChannel: .staff(staff), to: isMuted)
    }

    public func setStaffSolo(staff: Int, isSolo: Bool) {
        engine.setSoloed(forChannel: .staff(staff), to: isSolo)
    }

    public func setStaffInstrument(staff: Int, bank _: Int, program: Int) {
        engine.setProgram(
            forChannel: .staff(staff), to: UInt8(clamping: program)
        )
    }

    public func setMetronomeEnabled(_ enabled: Bool) {
        engine.setMuted(forChannel: .metronome, to: !enabled)
    }

    // Stubs — engine doesn't expose these yet; keep the protocol whole.
    public func setCursor(to _: ChordPath) {}
    public func setLoopRange(_: ABRepeatRange?) {}
    public func setTempoMultiplier(_: Double) {}
}
