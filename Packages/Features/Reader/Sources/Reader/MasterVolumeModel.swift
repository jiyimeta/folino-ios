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
    /// Committed master volume. `nil` = the user never chose one, so it resolves to
    /// `ReaderPreferences.defaultMasterVolume` (unity). Persisted raw by the parent via `onChange`, so an untouched
    /// score is never marked touched by an unrelated save.
    private(set) var value: Double?

    /// Transient slider write during a drag (or thumb-release writeback). Populated by `setValue`, cleared by
    /// `commitValue` / `resetValue`. Lives here so the slider tracks the finger without a plain `@State` clobbering a
    /// programmatic reset — same reason `TempoModel.liveMultiplier` exists.
    private(set) var liveValue: Double?

    @ObservationIgnored var onChange: (() async -> Void)?
    @ObservationIgnored var controllerProvider: () -> (any PlaybackController)? = { nil }

    /// Value the inspector slider should render — the in-flight drag value when present, else the committed value.
    var displayValue: Double {
        liveValue ?? value ?? ReaderPreferences.defaultMasterVolume
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
    /// post-clamp value to the engine. Storing `.some` even when the value lands exactly on unity is deliberate — an
    /// explicit choice is an explicit choice; only `resetValue` goes back to "untouched".
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

    /// Reset to the default (unity). Clears the saved value back to "untouched" and drops any transient drag value,
    /// then forwards the default to the engine.
    func resetValue() async {
        value = nil
        liveValue = nil
        await onChange?()
        await controllerProvider()?.setMasterVolume(ReaderPreferences.defaultMasterVolume)
    }
}
