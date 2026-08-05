import SheetMusicCore

extension ReaderPreferences {
    /// Reconcile a score's authored-hidden staves (`Score.authoredHiddenStaffAddresses`) with the
    /// stored `ReaderPreferences` (`nil` when none exists yet), returning the value to use and
    /// whether it must be persisted. Shared by the iOS `ReaderPreferencesStore` and the Android
    /// `ReaderPreferencesBridge` so both platforms seed authored visibility identically.
    ///
    /// - No stored value → seed a fresh row that hides (and records as authored) whatever the score
    ///   authored hidden, marked seeded. It is persisted ONLY when the score actually authored
    ///   something hidden: a row that says nothing but "defaults" carries no information, and
    ///   writing one on first open would make every opened score look touched.
    /// - Stored, not yet seeded, and there ARE authored-hidden staves → one-time back-fill: union
    ///   them into whatever the user already hid, record them as the authored set, marked seeded.
    /// - Stored and seeded, but the recorded authored set differs from the score's → refresh just
    ///   the provenance. `hiddenStaves` is left alone, so a staff the user revealed stays revealed.
    ///   This is what makes the authored set self-healing for rows written before it existed and
    ///   for scores whose staves were renumbered by a re-read.
    /// - Otherwise (the recorded authored set already matches) → return the stored value unchanged
    ///   and do not write.
    public static func reconcilingAuthoredHidden(
        stored: ReaderPreferences?,
        authoredHiddenStaves: Set<StaffAddress>,
        scoreItemID: ScoreItemID,
    ) -> (preferences: ReaderPreferences, shouldPersist: Bool) {
        guard let stored else {
            let seeded = ReaderPreferences(
                scoreItemID: scoreItemID,
                hiddenStaves: authoredHiddenStaves,
                authoredHiddenStaves: authoredHiddenStaves,
                hasSeededAuthoredVisibility: true,
            )
            return (seeded, !authoredHiddenStaves.isEmpty)
        }
        if !stored.hasSeededAuthoredVisibility, !authoredHiddenStaves.isEmpty {
            var backfilled = stored
            backfilled.hiddenStaves.formUnion(authoredHiddenStaves)
            backfilled.authoredHiddenStaves = authoredHiddenStaves
            backfilled.hasSeededAuthoredVisibility = true
            return (backfilled, true)
        }
        if stored.authoredHiddenStaves != authoredHiddenStaves {
            var refreshed = stored
            refreshed.authoredHiddenStaves = authoredHiddenStaves
            return (refreshed, true)
        }
        return (stored, false)
    }
}
