import Foundation

/// Façade over the SheetMusicAudio engine. Owns the audio session lifetime,
/// the per-staff sampler graph, and the cursor stream that the Reader feature
/// observes for highlight animation.
public protocol PlaybackController: Sendable {
    /// Set up the engine for a score and seed it with the user's saved
    /// preferences. Subsequent setter calls update the live engine state.
    func load(score: Score, preferences: PlaybackPreferences) async throws

    /// Returns `true` when every sound source `load(score:preferences:)`
    /// would need is already on disk (bundled or in the on-disk cache).
    /// The Reader uses this to suppress the "loading sounds" alert on
    /// warm-cache loads — the user only sees it when something actually
    /// needs to download.
    func areSoundfontsAvailableLocally(for score: Score) async -> Bool

    /// True iff the soundfont for `(bank, program, isDrums)` is already
    /// on disk (bundled or cached). Mirrors
    /// `areSoundfontsAvailableLocally(for:)` at per-patch granularity —
    /// the Inspector instrument-pick path uses this to decide whether
    /// `setStaffInstrument` would fall back to a bundled patch.
    func isSoundfontCached(bank: Int, program: Int, isDrums: Bool) async -> Bool

    /// Download and cache a single patch. Resolves on success; throws
    /// `CancellationError` on `Task.cancel()`, or rethrows resolver
    /// failures. Idempotent — a no-op if the patch is already cached.
    func prefetchSoundfont(bank: Int, program: Int, isDrums: Bool) async throws

    func play() async throws
    func pause() async

    func setCursor(to cursor: ScoreCursor) async
    func setLoopRange(_ range: ABRepeatRange?) async
    func setMetronomeEnabled(_ enabled: Bool) async
    func setTempoMultiplier(_ value: Double) async

    func setStaffVolume(staff: Int, volume: Double) async
    func setStaffMute(staff: Int, isMuted: Bool) async
    func setStaffSolo(staff: Int, isSolo: Bool) async
    func setStaffInstrument(staff: Int, bank: Int, program: Int) async

    /// Register a handler invoked synchronously on every cursor change emitted
    /// by the engine. Replaces any previously registered handler. Receives
    /// `nil` when playback stops. `ScoreCursor` is re-exported from
    /// `SheetMusicCore` so Features can subscribe without depending on the
    /// audio package directly.
    ///
    /// Synchronous delivery (instead of `AsyncStream`) keeps each cursor
    /// change on its own MainActor work item — mirroring the engine's
    /// `@Published currentCursor` semantics — so SwiftUI gets a render
    /// opportunity between every change instead of seeing only the last
    /// value of a buffered burst.
    @MainActor func observeCursor(_ handler: @MainActor @escaping (ScoreCursor?) -> Void)
}
