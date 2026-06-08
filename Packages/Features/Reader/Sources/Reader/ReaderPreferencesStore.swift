import Domain
import Foundation

/// Loads, seeds, and persists `ReaderPreferences` for a single `ScoreItem`. The store re-runs
/// `ReaderPreferences.init` after every mutation so the type's clamping rules always apply, and
/// it never reaches into the view model's sub-models — distribution of loaded preferences is the
/// caller's job (see `ReaderViewModel.load()`).
@MainActor
final class ReaderPreferencesStore {
    private(set) var preferences: ReaderPreferences

    private let repository: any ScoreLibraryRepository
    private let scoreItemID: ScoreItem.ID
    private let defaultStaffSize: Double

    init(
        scoreItemID: ScoreItem.ID,
        defaultStaffSize: Double,
        repository: any ScoreLibraryRepository,
    ) {
        self.scoreItemID = scoreItemID
        self.defaultStaffSize = defaultStaffSize
        self.repository = repository
        preferences = ReaderPreferences(
            scoreItemID: scoreItemID,
            staffSize: defaultStaffSize,
            hiddenStaves: [],
        )
    }

    /// Loads the persisted preferences if any, otherwise seeds defaults and writes them through. Either way
    /// the resolved value lands in `preferences` and is returned for the caller to distribute into sub-models.
    @discardableResult
    func loadOrSeed() async -> ReaderPreferences {
        do {
            if let stored = try await repository.loadReaderPreferences(for: scoreItemID) {
                preferences = stored
                return stored
            }
        } catch {
            // Persistence error is non-fatal; fall through to seed defaults.
        }
        let seeded = ReaderPreferences(
            scoreItemID: scoreItemID,
            staffSize: defaultStaffSize,
            hiddenStaves: [],
        )
        preferences = seeded
        try? await repository.saveReaderPreferences(seeded)
        return seeded
    }

    /// Applies `apply` to a working copy, then re-seats through `ReaderPreferences.init` so clamping rules
    /// always run. The normalized value lands in `preferences` and is persisted.
    func mutate(_ apply: (inout ReaderPreferences) -> Void) async {
        var copy = preferences
        apply(&copy)
        let normalized = ReaderPreferences(
            id: copy.id,
            scoreItemID: copy.scoreItemID,
            staffSize: copy.staffSize,
            hiddenStaves: copy.hiddenStaves,
            staffProgramOverrides: copy.staffProgramOverrides,
            staffVolumeOverrides: copy.staffVolumeOverrides,
            staffClefOverrides: copy.staffClefOverrides,
            tempoMultiplier: copy.tempoMultiplier,
            honorLayoutBreaks: copy.honorLayoutBreaks,
            repeatMode: copy.repeatMode,
            abRepeat: copy.abRepeat,
            masterVolume: copy.masterVolume,
            transposeSemitones: copy.transposeSemitones,
        )
        preferences = normalized
        try? await repository.saveReaderPreferences(normalized)
    }
}
