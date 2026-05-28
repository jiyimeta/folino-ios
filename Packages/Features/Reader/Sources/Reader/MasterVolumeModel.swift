import Domain
import Observation

/// Owns the Reader's per-score master output volume. `1.0` (unity) plays the score at its authored level; the slider
/// boosts up to `ReaderPreferences.maxMasterVolume` (300%) to lift quietly-authored scores or low-output soundfonts
/// past per-staff CC7's ceiling. The audio engine brick-wall-limits the boost so it doesn't hard-clip.
///
/// Structured like `TempoModel`: a committed `value` (the persistent slice) plus a transient `liveValue` written during
/// a slider drag, so `PlaybackInspectorScreen`'s `ResettableSlider` can bind directly to the model and have its
/// release-time writeback authoritatively cleared on reset.
@MainActor
@Observable
final class MasterVolumeModel {
    /// Committed master volume. `1.0` = unity. Persisted by the parent via `onChange`.
    private(set) var value = 1.0

    /// Transient slider write during a drag (or thumb-release writeback). Populated by `setValue`, cleared by
    /// `commitValue` / `resetValue`. Lives here so the slider tracks the finger without a plain `@State` clobbering a
    /// programmatic reset — same reason `TempoModel.liveMultiplier` exists.
    private(set) var liveValue: Double?

    @ObservationIgnored var onChange: (() async -> Void)?
    @ObservationIgnored var controllerProvider: () -> (any PlaybackController)? = { nil }

    /// Value the inspector slider should render — the in-flight drag value when present, else the committed value.
    var displayValue: Double {
        liveValue ?? value
    }

    func sync(from prefs: ReaderPreferences) {
        value = prefs.masterVolume
    }

    /// Drag-time slider write — stores the transient value and forwards to the engine for audible feedback. Does NOT
    /// persist; the View calls `commitValue(_:)` on slider release.
    func setValue(_ newValue: Double) {
        liveValue = newValue
        let controller = controllerProvider()
        Task { await controller?.setMasterVolume(newValue) }
    }

    /// Slider release: clamp to the supported window, persist, clear the transient drag value, and forward the
    /// post-clamp value to the engine.
    func commitValue(_ newValue: Double) async {
        let clamped = min(
            max(newValue, ReaderPreferences.minMasterVolume),
            ReaderPreferences.maxMasterVolume,
        )
        value = clamped
        liveValue = nil
        await onChange?()
        await controllerProvider()?.setMasterVolume(clamped)
    }

    /// Reset to unity (100%). Clears the saved value and any transient drag value, then forwards `1.0`.
    func resetValue() async {
        value = 1.0
        liveValue = nil
        await onChange?()
        await controllerProvider()?.setMasterVolume(1.0)
    }
}
