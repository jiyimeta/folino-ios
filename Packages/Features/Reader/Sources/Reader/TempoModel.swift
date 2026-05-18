import Domain
import Observation

/// Owns the Reader's playback-rate override and the metronome forwarding hook. Persistent slice is `multiplier` (nil =
/// native tempo); the metronome itself isn't persisted at this layer — `@AppStorage` in the root screen does that — but
/// the forward-to-controller call lives here so the playback transport surface is one model.
@MainActor
@Observable
final class TempoModel {
    /// Nil means "no override; play at the score's native tempo." Mirrors the optional field in `ReaderPreferences` so
    /// the parent can persist without an extra projection layer.
    private(set) var multiplier: Double?

    /// Transient slider write during a drag (or thumb-release writeback). Populated by `setMultiplier`, cleared by
    /// `commitMultiplier` / `resetMultiplier`. Lives here so the inspector slider can bind directly to the model —
    /// without this, the slider's release-time writeback would overwrite a programmatic reset because SwiftUI's
    /// `@State` is too direct a target.
    private(set) var liveMultiplier: Double?

    @ObservationIgnored var onChange: (() async -> Void)?
    @ObservationIgnored var controllerProvider: () -> (any PlaybackController)? = { nil }

    /// Convenience for views that don't care about the nil-vs-default distinction — they just need the value to seed
    /// slider state. Reads only the committed multiplier so a mid-drag value doesn't leak out (existing tests assert
    /// this).
    var effectiveMultiplier: Double {
        multiplier ?? 1.0
    }

    /// Value the inspector slider should render — picks up the in-flight drag value when present so the thumb tracks
    /// the user's finger, and falls back to the committed override otherwise.
    var displayMultiplier: Double {
        liveMultiplier ?? multiplier ?? 1.0
    }

    func sync(from prefs: ReaderPreferences) {
        multiplier = prefs.tempoMultiplier
    }

    /// Drag-time slider write — stores the transient value, forwards to the engine for audible feedback, and does NOT
    /// persist. The View calls `commitMultiplier(_:)` on slider release.
    func setMultiplier(_ value: Double) {
        liveMultiplier = value
        let controller = controllerProvider()
        Task { await controller?.setTempoMultiplier(value) }
    }

    /// Slider release: persist the override (normalizing 1.0 → nil, clamping out-of-range slider values to the
    /// supported window) and forward the post-clamp value to the engine.
    func commitMultiplier(_ value: Double) async {
        // Snap "100% to display" back to the no-override state. Slider can stop at e.g. 0.9999999... when visually
        // centred; without this, the override persists as a near-1.0 value the user thought they cleared.
        let normalized: Double? = if abs(value - 1.0) < 0.005 {
            nil
        } else {
            min(
                max(value, ReaderPreferences.minTempoMultiplier),
                ReaderPreferences.maxTempoMultiplier,
            )
        }
        multiplier = normalized
        liveMultiplier = nil
        await onChange?()
        await controllerProvider()?.setTempoMultiplier(effectiveMultiplier)
    }

    /// Reset to native tempo. Clears both the saved override and any transient drag value, then forwards 1.0.
    func resetMultiplier() async {
        multiplier = nil
        liveMultiplier = nil
        await onChange?()
        await controllerProvider()?.setTempoMultiplier(1.0)
    }

    /// Forward metronome on/off to the engine. Persistence is owned by the View layer via
    /// `@AppStorage("readerMetronomeEnabled")` so it survives across scores.
    func setMetronomeEnabled(_ enabled: Bool) async {
        await controllerProvider()?.setMetronomeEnabled(enabled)
    }
}
