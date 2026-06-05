import Foundation

/// Façade over the SheetMusicAudio engine. Owns the audio session lifetime, the per-staff sampler graph, and the cursor
/// stream that the Reader feature observes for highlight animation.
public protocol PlaybackController: Sendable {
    /// Set up the engine for a score and seed it with the user's saved preferences. Subsequent setter calls update the
    /// live engine state.
    ///
    /// `displayTitle` overrides the score's embedded title metadata for the lock-screen / Control Center Now Playing
    /// title. The Library row's filename-based title is passed here so users see the same name they picked in the
    /// Library, not whatever the source file's `<work-title>` happens to be (often missing or auto-generated).
    func load(
        score: Score, displayTitle: String?, preferences: PlaybackPreferences,
    ) async throws

    func play() async throws
    func pause() async

    /// Tear down the audio engine and deactivate the audio session so the system can resume normal auto-lock behavior.
    /// A subsequent `load(score:displayTitle:preferences:)` re-prepares the engine and re-activates the session. The
    /// Reader calls this on `.onDisappear` because `engine.prepare(...)` ends with `AVAudioEngine.start()` (and only
    /// pauses it), which iOS treats as active audio output and which would otherwise inhibit screen lock for the rest
    /// of the app's lifetime.
    func releaseEngine() async

    /// Re-prepare the currently loaded score so the engine re-consults its `SoundfontResolver`. Preserves the cursor
    /// position and re-applies per-staff volume / mute / solo / tempo from the original `load` preferences. Stays
    /// paused after the swap regardless of prior playing state — the Reader is responsible for calling this only when
    /// `isPlaying == false`, so a soundfont swap never cuts active audio. No-op when no score is currently loaded.
    func reloadSoundfont() async

    /// Current playback position in seconds. Zero before a score is loaded and prepared. Read main-actor synchronously
    /// — the engine computes this from its sequencer state on the main thread, so no actor hop is needed.
    @MainActor var currentTimeSeconds: TimeInterval { get }
    /// Total playable duration of the loaded score in seconds. Zero before a score is loaded.
    @MainActor var totalTimeSeconds: TimeInterval { get }

    /// Skip playback forward (`seconds > 0`) or backward (`seconds < 0`) relative to the current position, clamped to
    /// the score's range. Preserves play / pause state.
    func skip(bySeconds seconds: TimeInterval) async

    func setCursor(to cursor: ScoreCursor) async
    func setLoopRange(_ range: ABRepeatRange?) async
    func setMetronomeEnabled(_ enabled: Bool) async
    func setTempoMultiplier(_ value: Double) async

    /// Set the per-score master output volume. `1.0` is unity (the authored mix); values up to `3.0` (300%) boost the
    /// whole mix past per-staff CC7's ceiling, with a downstream limiter preventing hard clipping. Out-of-range values
    /// are clamped by the adapter.
    func setMasterVolume(_ value: Double) async

    /// Retune playback to an A4 reference, expressed as a cents offset from 440 Hz
    /// (use `A4Reference.cents(forHz:)`). Playback only — notation is unchanged.
    func setMasterTuning(cents: Double) async

    func setStaffVolume(staff: Int, volume: Double) async
    func setStaffMute(staff: Int, isMuted: Bool) async
    func setStaffSolo(staff: Int, isSolo: Bool) async
    func setStaffInstrument(staff: Int, bank: Int, program: Int) async

    /// Register a handler invoked synchronously on every cursor change emitted by the engine. Replaces any previously
    /// registered handler. Receives `nil` when playback stops. `ScoreCursor` is re-exported from `SheetMusicCore` so
    /// Features can subscribe without depending on the audio package directly.
    ///
    /// Synchronous delivery (instead of `AsyncStream`) keeps each cursor change on its own MainActor work item —
    /// mirroring the engine's observable `currentCursor` semantics — so SwiftUI gets a render opportunity between every
    /// change instead of seeing only the last value of a buffered burst.
    @MainActor func observeCursor(_ handler: @MainActor @escaping (ScoreCursor?) -> Void)

    /// Register a handler invoked on every play/pause transition, including pauses triggered from outside the app
    /// (lock-screen control, headphone pause, audio interruption). Receives `true` when playback is active, `false`
    /// otherwise. Replaces any previously registered handler.
    @MainActor func observeIsPlaying(_ handler: @MainActor @escaping (Bool) -> Void)
}
