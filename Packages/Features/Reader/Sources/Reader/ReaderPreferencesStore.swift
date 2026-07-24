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
    ///
    /// `authoredHiddenStaves` are the staves the score file authored as hidden (MuseScore `<Part><show>0</show>`, via
    /// `Score.authoredHiddenStaffAddresses`). They open hidden by default: a brand-new row seeds them directly, and a
    /// row created before this feature is back-filled with them ONCE (unioned with anything the user already hid) and
    /// then marked seeded. On every subsequent open the stored row wins untouched, so a staff the user reveals stays
    /// revealed. Callers with no notation score (PDFs) pass the empty default.
    @discardableResult
    func loadOrSeed(authoredHiddenStaves: Set<StaffAddress> = []) async -> ReaderPreferences {
        do {
            if let stored = try await repository.loadReaderPreferences(for: scoreItemID) {
                // Loading an existing row stays read-only unless there are authored-hidden staves to
                // back-fill into a pre-feature row. A score with nothing authored-hidden (the common
                // case) never triggers a write on open — its `hasSeededAuthoredVisibility` is
                // irrelevant since there is nothing to re-hide.
                guard !stored.hasSeededAuthoredVisibility, !authoredHiddenStaves.isEmpty else {
                    preferences = stored
                    return stored
                }
                var backfilled = stored
                backfilled.hiddenStaves.formUnion(authoredHiddenStaves)
                backfilled.hasSeededAuthoredVisibility = true
                preferences = backfilled
                try? await repository.saveReaderPreferences(backfilled)
                return backfilled
            }
        } catch {
            // Persistence error is non-fatal; fall through to seed defaults.
        }
        let seeded = ReaderPreferences(
            scoreItemID: scoreItemID,
            staffSize: defaultStaffSize,
            hiddenStaves: authoredHiddenStaves,
            hasSeededAuthoredVisibility: true,
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
            a4ReferenceHz: copy.a4ReferenceHz,
            hasSeededAuthoredVisibility: copy.hasSeededAuthoredVisibility,
        )
        preferences = normalized
        try? await repository.saveReaderPreferences(normalized)
    }
}
