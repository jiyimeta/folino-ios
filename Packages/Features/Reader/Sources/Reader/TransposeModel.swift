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
    /// Committed transposition offset in semitones. `0` = no transposition.
    private(set) var semitones = 0

    @ObservationIgnored var onChange: (() async -> Void)?
    @ObservationIgnored var controllerProvider: () -> (any PlaybackController)? = { nil }

    func sync(from prefs: ReaderPreferences) {
        semitones = prefs.transposeSemitones
    }

    /// Set the transposition to `value`, clamped to `[-7, +7]`. Forwards to the engine and calls
    /// `onChange` only when the value actually changes.
    func setSemitones(_ value: Int) async {
        let clamped = max(-7, min(7, value))
        guard clamped != semitones else { return }
        semitones = clamped
        await controllerProvider()?.setTranspose(semitones: clamped)
        await onChange?()
    }

    /// Reset to no transposition (0 semitones).
    func reset() async {
        await setSemitones(0)
    }
}
