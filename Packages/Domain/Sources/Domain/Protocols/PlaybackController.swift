import Foundation

/// Façade over the SheetMusicAudio engine. Owns the audio session lifetime,
/// the per-staff sampler graph, and the cursor stream that the Reader feature
/// observes for highlight animation.
public protocol PlaybackController: Sendable {
    /// Set up the engine for a score and seed it with the user's saved
    /// preferences. Subsequent setter calls update the live engine state.
    func load(score: Score, preferences: PlaybackPreferences) async throws
    func play() async throws
    func pause() async

    func setCursor(to chord: ChordPath) async
    func setLoopRange(_ range: ABRepeatRange?) async
    func setMetronomeEnabled(_ enabled: Bool) async
    func setTempoMultiplier(_ value: Double) async

    func setStaffVolume(staff: Int, volume: Double) async
    func setStaffMute(staff: Int, isMuted: Bool) async
    func setStaffSolo(staff: Int, isSolo: Bool) async
    func setStaffInstrument(staff: Int, bank: Int, program: Int) async

    /// Cursor positions emitted by the engine while playing. Yields `nil` when
    /// playback stops. `ScoreCursor` is re-exported from `SheetMusicCore` so
    /// Features can subscribe without depending on the audio package directly.
    var cursor: AsyncStream<ScoreCursor?> { get }
}
