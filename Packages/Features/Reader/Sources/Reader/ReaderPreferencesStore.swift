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

    init(
        scoreItemID: ScoreItem.ID,
        repository: any ScoreLibraryRepository,
    ) {
        self.scoreItemID = scoreItemID
        self.repository = repository
        // Placeholder until `loadOrSeed` runs. Every Optional field stays `nil` — an untouched score must not look
        // touched just because the Reader stood a store up for it.
        preferences = ReaderPreferences(scoreItemID: scoreItemID, hiddenStaves: [])
    }

    /// Loads the persisted preferences if any, otherwise seeds a fresh value. Either way the resolved value lands in
    /// `preferences` and is returned for the caller to distribute into sub-models. A seed is written through only when
    /// it actually records something (see `reconcilingAuthoredHidden`) — a row that says nothing but "defaults" would
    /// make every score the user merely opened look like one they configured.
    ///
    /// `authoredHiddenStaves` are the staves the score file authored as hidden (MuseScore `<Part><show>0</show>`, via
    /// `Score.authoredHiddenStaffAddresses`). They open hidden by default: a brand-new row seeds them directly, and a
    /// row created before this feature is back-filled with them ONCE (unioned with anything the user already hid) and
    /// then marked seeded. On every subsequent open the stored `hiddenStaves` wins, so a staff the user reveals stays
    /// revealed — but `authoredHiddenStaves` is refreshed and rewritten whenever it disagrees with the score, keeping
    /// the provenance correct across re-reads that renumber staves.
    ///
    /// Because of that refresh, `authoredHiddenStaves` must only ever be the *known* authored set: passing `[]` for a
    /// notation score whose parse failed or is incomplete would permanently reclassify its authored-hidden staves as
    /// user-hidden. Callers with no notation score at all (PDFs) pass the empty default legitimately. See the caller
    /// contract on `ReaderPreferences.reconcilingAuthoredHidden`.
    @discardableResult
    func loadOrSeed(authoredHiddenStaves: Set<StaffAddress> = []) async -> ReaderPreferences {
        // A persistence error is non-fatal — `try?` collapses "no row" and "load failed" alike into
        // the no-stored-value seed path. `reconcilingAuthoredHidden` is the shared iOS/Android rule.
        let stored = await (try? repository.loadReaderPreferences(for: scoreItemID))
        let (resolved, shouldPersist) = ReaderPreferences.reconcilingAuthoredHidden(
            stored: stored,
            authoredHiddenStaves: authoredHiddenStaves,
            scoreItemID: scoreItemID,
        )
        preferences = resolved
        if shouldPersist {
            try? await repository.saveReaderPreferences(resolved)
        }
        return resolved
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
            authoredHiddenStaves: copy.authoredHiddenStaves,
            stripProgramOverrides: copy.stripProgramOverrides,
            stripVolumeOverrides: copy.stripVolumeOverrides,
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
