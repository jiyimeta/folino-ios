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
    private var loadedScore: Score?

    private let cursorContinuation: AsyncStream<ChordPath?>.Continuation
    public nonisolated let cursor: AsyncStream<ChordPath?>

    public init(soundfontResolver: any SheetMusicAudio.SoundfontResolver) {
        engine = PlaybackEngine(soundfontResolver: soundfontResolver)
        var continuation: AsyncStream<ChordPath?>.Continuation!
        cursor = AsyncStream { continuation = $0 }
        cursorContinuation = continuation
    }

    public func load(score: Score, preferences: PlaybackPreferences) throws {
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
