import Domain
import Observation

/// Owns the Reader's playback-rate override and the metronome forwarding
/// hook. Persistent slice is `multiplier` (nil = native tempo); the
/// metronome itself isn't persisted at this layer — `@AppStorage` in the
/// root screen does that — but the forward-to-controller call lives here
/// so the playback transport surface is one model.
@MainActor
@Observable
final class TempoModel {
    /// Nil means "no override; play at the score's native tempo." Mirrors
    /// the optional field in `ReaderPreferences` so the parent can persist
    /// without an extra projection layer.
    private(set) var multiplier: Double?

    @ObservationIgnored var onChange: (() async -> Void)?
    @ObservationIgnored var controllerProvider: () -> (any PlaybackController)? = { nil }

    /// Convenience for views that don't care about the nil-vs-default
    /// distinction — they just need the value to seed slider state.
    var effectiveMultiplier: Double {
        multiplier ?? 1.0
    }

    func sync(from prefs: ReaderPreferences) {
        multiplier = prefs.tempoMultiplier
    }

    /// Drag-time slider write — forwards immediately to the engine for
    /// audible feedback but does NOT persist. The View calls
    /// `commitMultiplier(_:)` on slider release.
    func setMultiplier(_ value: Double) {
        let controller = controllerProvider()
        Task { await controller?.setTempoMultiplier(value) }
    }

    /// Slider release: persist the override (normalizing 1.0 → nil,
    /// clamping out-of-range slider values to the supported window) and
    /// forward the post-clamp value to the engine.
    func commitMultiplier(_ value: Double) async {
        // Snap "100% to display" back to the no-override state. Slider can
        // stop at e.g. 0.9999999... when visually centred; without this,
        // the override persists as a near-1.0 value the user thought
        // they cleared.
        let normalized: Double? = if abs(value - 1.0) < 0.005 {
            nil
        } else {
            min(
                max(value, ReaderPreferences.minTempoMultiplier),
                ReaderPreferences.maxTempoMultiplier,
            )
        }
        multiplier = normalized
        await onChange?()
        await controllerProvider()?.setTempoMultiplier(effectiveMultiplier)
    }

    /// Reset to native tempo. Clears the saved override and forwards 1.0.
    func resetMultiplier() async {
        multiplier = nil
        await onChange?()
        await controllerProvider()?.setTempoMultiplier(1.0)
    }

    /// Forward metronome on/off to the engine. Persistence is owned by
    /// the View layer via `@AppStorage("readerMetronomeEnabled")` so it
    /// survives across scores.
    func setMetronomeEnabled(_ enabled: Bool) async {
        await controllerProvider()?.setMetronomeEnabled(enabled)
    }
}
