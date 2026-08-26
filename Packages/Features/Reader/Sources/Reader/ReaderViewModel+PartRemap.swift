import Domain
import SheetMusicCore

extension ReaderViewModel {
    /// Re-seats every in-memory per-score preference from the row the Editor has just migrated through a part
    /// add / remove / reorder (`EditorViewModel.onPartIndicesRemapped`).
    ///
    /// Migrating the persisted row is only half the fix. `LayoutSettingsModel` (hidden staves, per-staff clef
    /// overrides) and `PlaybackMixerModel` (the strip program / volume overlays) hold the same part-indexed state
    /// live for the length of the session, and THAT copy is what the next preference write persists — so without
    /// this the migrated row is clobbered by the stale one the moment the reader touches any setting, and until then
    /// the reader is looking at the wrong staff hidden.
    ///
    /// The order matters. A write started elsewhere is joined FIRST (`flushPendingWrites`), because a write still in
    /// the air would land on top of the row we are about to read. Only then is the row re-read and redistributed —
    /// deliberately through the normal `loadOrSeedPreferences` path, so the authored-visibility reconcile and every
    /// sub-model's `sync(from:)` run exactly as they do on open, rather than a second copy of that logic drifting
    /// from it.
    ///
    /// `authoredHiddenStaves` must come from the POST-edit score (the editing host's `editedScore`), not from
    /// `loadState.score` — the latter is still the score the session opened on, whose part numbering is the one that
    /// just went away. See the caller contract on `ReaderPreferences.reconcilingAuthoredHidden`: handing this the
    /// wrong set silently rewrites the provenance.
    func reloadPreferencesAfterPartRemap(authoredHiddenStaves: Set<StaffAddress>) async {
        await flushPendingPreferenceWrites()
        await loadOrSeedPreferences(authoredHiddenStaves: authoredHiddenStaves)
        // The same two side effects `layoutModel.onHiddenStavesChanged` fires, because the hidden set may well have
        // moved: the cursor's staff translation is derived from it, and a live PiP renderer was built against the
        // old one. The rendered editing surface needs no nudge — it reads `layoutModel` through observation.
        recomputeVisibleScore()
        playbackSession.refreshTranslation()
        pipSession.dismissIfActive()
    }
}
