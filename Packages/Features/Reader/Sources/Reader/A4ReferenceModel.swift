import Domain
import Observation

/// Owns the Reader's per-score A4 reference-frequency override. `nil` means "inherit the global default"; a set value
/// overrides for this score only (clamped to `[A4Reference.minHz, A4Reference.maxHz]`).
///
/// Structured like `MasterVolumeModel`: a committed `value` (the persistent slice) plus a transient `liveValue`
/// written during a slider drag. `PlaybackInspectorScreen` binds directly to this model so release-time writeback is
/// authoritatively cleared on reset — a plain `@State` target would be overwritten by the slider's internal writeback
/// and silently revert the reset.
@MainActor
@Observable
final class A4ReferenceModel {
    /// Committed per-score override in Hz. `nil` = inherit global default. Persisted by the parent via `onChange`.
    private(set) var value: Double?

    /// Transient slider write during a drag (or thumb-release writeback). Populated by `setValue`, cleared by
    /// `commitValue` / `resetValue`.
    private(set) var liveValue: Double?

    @ObservationIgnored var onChange: (() async -> Void)?
    @ObservationIgnored var controllerProvider: () -> (any PlaybackController)? = { nil }
    /// Reads the current global A4 default so the engine can be updated with the resolved effective Hz.
    @ObservationIgnored var globalDefaultProvider: () -> Double = { A4Reference.standardHz }

    /// Hz the inspector slider should render — in-flight drag value when present, else the committed override; falls
    /// back to the global default when no override is active and no drag is in progress.
    var displayHz: Double {
        liveValue ?? value ?? globalDefaultProvider()
    }

    /// Whether a per-score override is currently active (the row is in an overriding state vs. inheriting the global
    /// default).
    var isOverriding: Bool {
        value != nil
    }

    /// The current global A4 default in Hz. The inspector shows the per-score value relative to this baseline.
    var globalDefaultHz: Double {
        globalDefaultProvider()
    }

    func sync(from prefs: ReaderPreferences) {
        value = prefs.a4ReferenceHz
    }

    /// Drag-time slider write — stores the transient value and forwards to the engine for audible feedback. Does NOT
    /// persist; the View calls `commitValue(_:)` on slider release.
    func setValue(_ hz: Double) {
        liveValue = hz
        let controller = controllerProvider()
        let cents = A4Reference.cents(forHz: hz)
        Task { await controller?.setMasterTuning(cents: cents) }
    }

    /// Slider release: clamp to `A4Reference` bounds, persist as the per-score override, clear the transient drag
    /// value, and forward the post-clamp effective cents to the engine.
    func commitValue(_ hz: Double) async {
        let clamped = A4Reference.clamp(hz)
        value = clamped
        liveValue = nil
        await onChange?()
        let cents = A4Reference.cents(forHz: clamped)
        await controllerProvider()?.setMasterTuning(cents: cents)
    }

    /// Clear the per-score override, falling back to the global default. Clears any transient drag value, persists
    /// `nil`, and forwards the global default's cents to the engine.
    func resetValue() async {
        value = nil
        liveValue = nil
        await onChange?()
        let effectiveHz = globalDefaultProvider()
        let cents = A4Reference.cents(forHz: effectiveHz)
        await controllerProvider()?.setMasterTuning(cents: cents)
    }
}
