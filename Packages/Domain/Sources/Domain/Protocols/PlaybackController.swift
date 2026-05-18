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

    /// Returns `true` when every sound source `load(score:preferences:)` would need is already on disk (bundled or in
    /// the on-disk cache). The Reader uses this to suppress the "loading sounds" alert on warm-cache loads — the user
    /// only sees it when something actually needs to download.
    func areSoundfontsAvailableLocally(for score: Score) async -> Bool

    /// True iff the soundfont for `(bank, program, isDrums)` is already on disk (bundled or cached). Mirrors
    /// `areSoundfontsAvailableLocally(for:)` at per-patch granularity — the Inspector instrument-pick path uses this to
    /// decide whether `setStaffInstrument` would fall back to a bundled patch.
    func isSoundfontCached(bank: Int, program: Int, isDrums: Bool) async -> Bool

    /// Download and cache a single patch. Resolves on success; throws `CancellationError` on `Task.cancel()`, or
    /// rethrows resolver failures. Idempotent — a no-op if the patch is already cached.
    func prefetchSoundfont(bank: Int, program: Int, isDrums: Bool) async throws

    func play() async throws
    func pause() async

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

    func setStaffVolume(staff: Int, volume: Double) async
    func setStaffMute(staff: Int, isMuted: Bool) async
    func setStaffSolo(staff: Int, isSolo: Bool) async
    func setStaffInstrument(staff: Int, bank: Int, program: Int) async

    /// Register a handler invoked synchronously on every cursor change emitted by the engine. Replaces any previously
    /// registered handler. Receives `nil` when playback stops. `ScoreCursor` is re-exported from `SheetMusicCore` so
    /// Features can subscribe without depending on the audio package directly.
    ///
    /// Synchronous delivery (instead of `AsyncStream`) keeps each cursor change on its own MainActor work item —
    /// mirroring the engine's `@Published currentCursor` semantics — so SwiftUI gets a render opportunity between every
    /// change instead of seeing only the last value of a buffered burst.
    @MainActor func observeCursor(_ handler: @MainActor @escaping (ScoreCursor?) -> Void)

    /// Register a handler invoked on every play/pause transition, including pauses triggered from outside the app
    /// (lock-screen control, headphone pause, audio interruption). Receives `true` when playback is active, `false`
    /// otherwise. Replaces any previously registered handler.
    @MainActor func observeIsPlaying(_ handler: @MainActor @escaping (Bool) -> Void)
}
