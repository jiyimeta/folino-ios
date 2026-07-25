import SheetMusicCore

extension ReaderPreferences {
    /// Reconcile a score's authored-hidden staves (`Score.authoredHiddenStaffAddresses`) with the
    /// stored `ReaderPreferences` (`nil` when none exists yet), returning the value to use and
    /// whether it must be persisted. Shared by the iOS `ReaderPreferencesStore` and the Android
    /// `ReaderPreferencesBridge` so both platforms seed authored visibility identically.
    ///
    /// - No stored value → seed a fresh row with the authored-hidden staves, marked seeded.
    /// - Stored, not yet seeded, and there ARE authored-hidden staves → one-time back-fill: union
    ///   them into whatever the user already hid, marked seeded.
    /// - Otherwise (already seeded, or nothing authored-hidden) → return the stored value unchanged,
    ///   so a staff the user revealed is never re-hidden and an all-visible score never writes.
    public static func reconcilingAuthoredHidden(
        stored: ReaderPreferences?,
        authoredHiddenStaves: Set<StaffAddress>,
        scoreItemID: ScoreItemID,
        defaultStaffSize: Double,
    ) -> (preferences: ReaderPreferences, shouldPersist: Bool) {
        guard let stored else {
            let seeded = ReaderPreferences(
                scoreItemID: scoreItemID,
                staffSize: defaultStaffSize,
                hiddenStaves: authoredHiddenStaves,
                hasSeededAuthoredVisibility: true,
            )
            return (seeded, true)
        }
        guard !stored.hasSeededAuthoredVisibility, !authoredHiddenStaves.isEmpty else {
            return (stored, false)
        }
        var backfilled = stored
        backfilled.hiddenStaves.formUnion(authoredHiddenStaves)
        backfilled.hasSeededAuthoredVisibility = true
        return (backfilled, true)
    }
}
