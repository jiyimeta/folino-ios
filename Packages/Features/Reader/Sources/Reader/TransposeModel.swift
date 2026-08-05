import Domain
import Observation

/// Owns the Reader's per-score transposition offset. `0` semitones means no transposition; the slider
/// goes from −7 to +7 (a diminished fifth either way), matching the engine's supported range.
///
/// Structured like `MasterVolumeModel` and `TempoModel`: a committed `semitones` (the persistent slice),
/// `controllerProvider` and `onChange` wired by the parent view model.
@MainActor
@Observable
final class TransposeModel {
    /// Committed transposition offset in semitones. `nil` = the user never chose one, so it resolves to
    /// `ReaderPreferences.defaultTransposeSemitones` (no transposition). Persisted raw so an untouched score stays
    /// untouched.
    private(set) var semitones: Int?

    @ObservationIgnored var onChange: (() async -> Void)?
    @ObservationIgnored var controllerProvider: () -> (any PlaybackController)? = { nil }

    /// Offset the renderer and the engine use. Everything that needs a number reads this, never `semitones`.
    var effectiveSemitones: Int {
        semitones ?? ReaderPreferences.defaultTransposeSemitones
    }

    func sync(from prefs: ReaderPreferences) {
        semitones = prefs.transposeSemitones
    }

    /// Set the transposition to `value`, clamped to `[-7, +7]`. Forwards to the engine and calls
    /// `onChange` only when the value actually changes.
    func setSemitones(_ value: Int) async {
        let clamped = max(-7, min(7, value))
        guard clamped != effectiveSemitones else { return }
        semitones = clamped
        await controllerProvider()?.setTranspose(semitones: clamped)
        await onChange?()
    }

    /// Reset to no transposition. Goes back to "untouched" (`nil`) rather than an explicit `0`, so the score stops
    /// counting as one the user transposed.
    func reset() async {
        guard semitones != nil else { return }
        semitones = nil
        await controllerProvider()?.setTranspose(semitones: ReaderPreferences.defaultTransposeSemitones)
        await onChange?()
    }
}
