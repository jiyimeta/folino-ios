import Combine
import Domain
import Foundation
import SheetMusicAudio
import SheetMusicCore

/// Bridges Folino's `Domain.PlaybackController` onto
/// `SheetMusicAudio.PlaybackEngine`. The engine is `@MainActor` so this
/// adapter is too — the protocol's `async` methods become hops onto the
/// main actor.
@MainActor
public final class LivePlaybackController: Domain.PlaybackController {
    private let engine: PlaybackEngine
    private let domainResolver: any Domain.SoundfontResolver
    private let precisionProbe: any Domain.PrecisePatchProbe
    private var loadedScore: Score?

    private let cursorContinuation: AsyncStream<ScoreCursor?>.Continuation
    public nonisolated let cursor: AsyncStream<ScoreCursor?>
    private var cancellables: Set<AnyCancellable> = []

    /// Bank / program of the bundled fallback patches. When a staff's
    /// precise SF2 is unavailable, the controller rewrites the staff's
    /// channel to one of these so the resolver's sync path returns the
    /// committed bundle file rather than an unrelated cached patch.
    static let pitchedFallbackChannel = (bank: 0, program: 73)
    static let drumFallbackChannel = (bank: 0, program: 0)

    public init(
        soundfontResolver: any SheetMusicAudio.SoundfontResolver,
        domainResolver: any Domain.SoundfontResolver,
        precisionProbe: any Domain.PrecisePatchProbe
    ) {
        engine = PlaybackEngine(soundfontResolver: soundfontResolver)
        self.domainResolver = domainResolver
        self.precisionProbe = precisionProbe
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
        await Self.prefetchSoundfonts(score: score, resolver: domainResolver)
        // Prefetch's URLSession calls honor cancellation but the TaskGroup
        // returns regardless. Bail before the engine prepare so a cancel
        // mid-load doesn't end up with a primed engine the user expects to
        // be silent.
        try Task.checkCancellation()
        let prepared = Self.scoreWithFallbackRewrites(score, probe: precisionProbe)
        try engine.prepare(score: prepared)
        loadedScore = prepared
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

    /// Walks the score's distinct `(bank, program, isDrums)` triples and
    /// asks the resolver to materialise each on disk, in parallel.
    /// Soft-fails per patch — if one download 404s, the others still land.
    /// Patches that fail outright are handled later by
    /// `scoreWithFallbackRewrites` rewriting the staff channel.
    private static func prefetchSoundfonts(
        score: Score, resolver: any Domain.SoundfontResolver
    ) async {
        var seen: Set<SoundfontPatchKey> = []
        var triples: [(bank: Int, program: Int, isDrums: Bool)] = []
        for entry in score.allStaves {
            guard let part = score.part(at: entry.address) else { continue }
            let channel = part.instrument.channels.first ?? InstrumentChannel()
            let isDrums = part.instrument.useDrumset
            let key = SoundfontPatchKey(
                bank: channel.bank, program: channel.program, isDrums: isDrums
            )
            if seen.insert(key).inserted {
                triples.append((channel.bank, channel.program, isDrums))
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for triple in triples {
                group.addTask {
                    _ = try? await resolver.resolveSoundfont(
                        bank: triple.bank, program: triple.program,
                        isDrums: triple.isDrums
                    )
                }
            }
        }
    }

    /// Returns a `Score` where every staff whose `(bank, program, isDrums)`
    /// has no precise SF2 file (cache or bundle) is rewritten to the
    /// matching bundled fallback channel (`(0, 73)` for pitched,
    /// `(0, 0)` for drums). Staves whose patch *is* available pass
    /// through unmodified.
    ///
    /// `swift-sheet-music`'s `Score` doesn't expose a `setPart(_:at:)`
    /// mutator — `parts` is a public mutable array — so this rewrites
    /// the part by index lookup off `StaffAddress.partIndex`.
    static func scoreWithFallbackRewrites(
        _ score: Score, probe: any Domain.PrecisePatchProbe
    ) -> Score {
        var rewritten = score
        for entry in rewritten.allStaves {
            let partIndex = entry.address.partIndex
            guard rewritten.parts.indices.contains(partIndex) else { continue }
            let part = rewritten.parts[partIndex]
            let channel = part.instrument.channels.first ?? InstrumentChannel()
            let isDrums = part.instrument.useDrumset
            if probe.precisePath(
                forBank: channel.bank, program: channel.program, isDrums: isDrums
            ) != nil {
                continue
            }
            let target = isDrums ? drumFallbackChannel : pitchedFallbackChannel
            var newChannel = channel
            newChannel.bank = target.bank
            newChannel.program = target.program
            if rewritten.parts[partIndex].instrument.channels.isEmpty {
                rewritten.parts[partIndex].instrument.channels = [newChannel]
            } else {
                rewritten.parts[partIndex].instrument.channels[0] = newChannel
            }
        }
        return rewritten
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

    public func setCursor(to cursor: ScoreCursor) {
        // `AVAudioSequencer` halts when `currentPositionInSeconds` is written
        // during playback, which kills the engine's own cursor timer on its
        // next tick (`tickCursor` early-outs on `!sequencer.isPlaying`). To
        // preserve "playback continues from the seeked position", route
        // through `play(from:in:)` while playing — that path writes the
        // position AND calls `sequencer.start()` AND restarts the cursor
        // timer in lockstep. Pure `seek` is fine while paused / stopped.
        if engine.state == .playing, let score = loadedScore {
            engine.play(from: cursor, in: score)
        } else {
            engine.seek(to: cursor)
        }
    }

    // Stubs — engine doesn't expose these yet; keep the protocol whole.
    public func setLoopRange(_: ABRepeatRange?) {}
    public func setTempoMultiplier(_: Double) {}
}
