import Domain
import SheetMusicCore

extension ReaderViewModel {
    /// Re-seats everything this process holds in memory by part index — the per-score preferences AND the score's ink
    /// — from the stores the Editor has just reconciled with a part add / remove / reorder
    /// (`EditorViewModel.onPartIndicesRemapped`), then lets go of whatever was held while that was in flight.
    ///
    /// Migrating the persisted row is only half the fix. `LayoutSettingsModel` (hidden staves, per-staff clef
    /// overrides) and `PlaybackMixerModel` (the strip program / volume overlays) hold the same part-indexed state
    /// live for the length of the session, and THAT copy is what the next preference write persists — so without
    /// this the migrated row is clobbered by the stale one the moment the reader touches any setting, and until then
    /// the reader is looking at the wrong staff hidden.
    ///
    /// The order is the whole design:
    ///
    /// 1. **Join writes already in the air.** One that lands after the re-read would put the row back to what it was
    ///    before the migration, and the Editor has consumed the map by then, so nothing would ever retry. The hold
    ///    is still up here, so no NEW write can be started behind it — which is also what makes the flush terminate
    ///    rather than chase writes it keeps admitting.
    /// 2. **Re-read and redistribute**, deliberately through the normal `loadOrSeedPreferences` path, so the
    ///    authored-visibility reconcile and every sub-model's `sync(from:)` run exactly as they do on open rather
    ///    than a second copy of that logic drifting from it. A load that FAILS re-seeds nothing — better to keep
    ///    holding the pre-migration values than to distribute defaults over them.
    /// 3. **Lift the hold — HERE, not when the Editor's save finished.** Until this line the sub-models were still
    ///    holding pre-migration addresses; dropping the flag any earlier would leave a window in which a write could
    ///    escape carrying exactly those, which is the second half of the corruption the hold exists to prevent.
    /// 4. **Let the deferred writes go — but ONLY if step 2 actually re-seeded.** The held closures read the
    ///    sub-models, so replaying them after a failed re-read persists the pre-migration addresses those models are
    ///    still holding, straight over the row the Editor has just migrated — with the map consumed, so nothing ever
    ///    retries. A failed re-read therefore discards the queue instead, the same policy the no-score bail in
    ///    `ReaderRootScreen.wirePartRemapReload` applies for the same reason. The hold still comes down either way:
    ///    leaving it up would strand it, which is the failure mode the release ordering was fixed to avoid.
    ///
    /// `authoredHiddenStaves` must come from the POST-edit score (the editing host's `editedScore`), not from
    /// `loadState.score` — the latter is still the score the session opened on, whose part numbering is the one that
    /// just went away. See the caller contract on `ReaderPreferences.reconcilingAuthoredHidden`: handing this the
    /// wrong set silently rewrites the provenance.
    ///
    /// - Parameter liftHold: performs the release and answers whether the hold actually came down. It answers
    ///   `false` when a second part edit is still unsettled, in which case the deferred writes stay held for that
    ///   edit's own release.
    func reloadPreferencesAfterPartRemap(
        authoredHiddenStaves: Set<StaffAddress>,
        liftHold: @MainActor () -> Bool,
    ) async {
        await flushPendingPreferenceWrites()
        let didReseed = await loadOrSeedPreferences(authoredHiddenStaves: authoredHiddenStaves)
        // The ink is the same problem in a second store: every stroke names its staff by part index, the Editor has
        // just rewritten those indices, and until this runs the containers are projecting the pre-migration anchors —
        // drawing each stroke over whichever instrument now sits where its part used to. Re-seeded BEFORE the hold
        // comes down, for the reason step 3 gives: until this line a capture would still be describing the old
        // numbering. See `reseedAnnotationsAfterPartRemap`.
        await reseedAnnotationsAfterPartRemap()
        if liftHold() {
            if didReseed {
                await applyDeferredPreferenceWrites()
            } else {
                discardDeferredPreferenceWrites()
            }
        }
        // The same two side effects `layoutModel.onHiddenStavesChanged` fires, because the hidden set may well have
        // moved: the cursor's staff translation is derived from it, and a live PiP renderer was built against the
        // old one. The rendered editing surface needs no nudge — it reads `layoutModel` through observation.
        recomputeVisibleScore()
        playbackSession.refreshTranslation()
        pipSession.dismissIfActive()
    }
}
