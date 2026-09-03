import Domain

// The two halves of the editing seam that the READER owns and every platform's screen installs from its `.task`:
// the revert reload and the part-remap hold / drain / release. Both were `ReaderRootScreen` extensions gated to iOS;
// they are `ReaderViewModel` methods now because the orchestration was always platform-neutral and the Mac screen
// installs the same two.

extension ReaderViewModel {
    /// Wires the revert half of the editing seam onto `host`, from the same `.task` block that fills its other
    /// providers (`sourceScoreProvider`, `hiddenStavesProvider`, …). Lives here, rather than on `ReaderRootScreen`
    /// or `MacReaderRootScreen` directly, because the wiring is platform-neutral and both screens install it.
    func wireRevertReload(host: ReaderEditingHost) {
        // The Editor cannot see the ink; only "anchored to the notation" counts, not ink pinned to a PDF page, which
        // a revert of the notation never touches.
        host.hasMusicalAnnotationsProvider = { [weak self] in
            self?.annotationDrawings.contains { drawing in
                if case .musical = drawing.kind {
                    true
                } else {
                    false
                }
            } ?? false
        }
        host.requestReloadAfterRevert = { [weak self, weak host] item in
            guard let self else { return }
            Task {
                // Stop first: the file under the audio engine is about to change, and this repo has a history of
                // crashes from tearing down or swapping under a live render thread (mirrors `advance(to:)`).
                await self.playbackSession.releaseEngine()
                self.scoreItem = item
                // The host is holding and drawing the edits the revert just discarded; leaving the session open
                // would leave the user looking at them. Same exit path the editing chrome's 完了 button uses — which,
                // on its normal path, re-adopts `editedScore` into the Reader (`finishEditing()`). That would race
                // this very reload with the pre-revert (now stale) score, so it is cleared first: `finishEditing()`'s
                // adoption becomes a no-op and `load()` below is left as the one write.
                host?.editedScore = nil
                host?.requestExit()
                if item.originalPDFFileName != nil {
                    // The geometry belongs to the parse the revert just discarded; the next switch to the original
                    // re-derives it (mirrors `reReadPDF()`'s tail).
                    self.pdfPlayback = .idle
                }
                await self.load()
            }
        }
    }

    /// Wires the part-remap half of the editing seam onto `host`, from the same `.task` block that fills its other
    /// providers. Lives here for the same reason `wireRevertReload` does: the wiring is platform-neutral and both
    /// `ReaderRootScreen` and `MacReaderRootScreen` install it.
    ///
    /// Three halves now. Both part-indexed writers — the preferences row and the annotation layer — are taught to hold
    /// while the host says a migration is unsettled; the drain is wired so whatever was already in the air lands
    /// BEFORE the Editor's migration reads; and the reload is wired to re-read both stores, release the hold, and let
    /// what was held go — in that order.
    func wirePartRemapReload(host: ReaderEditingHost) {
        setPartMigrationPendingProvider { [weak host] in
            host?.isPartMappingPending ?? false
        }
        // The annotation coordinator's own debounce is the thing being drained; the preference store's writes are
        // joined at the release instead, where `mutate` has already awaited each of them.
        host.prepareForPartMigration = { [weak self] in
            await self?.flushPendingAnnotationSave()
        }
        host.requestReloadAfterPartRemap = { [weak self, weak host] in
            // Two ways there is nothing to reload — this Reader is already gone, or the editing session no longer
            // has a score — and BOTH have to release. This closure is the only thing that ever lowers the flag, so
            // a bail that returns without it leaves a surviving host stuck at `isPartMappingPending == true` and
            // the next Reader on it never persists its preferences row again (round-3 Important). Hence one guard
            // covering both, with the release above everything.
            //
            // `editedScore` is the POST-edit score, and there is no safe fallback to `loadState.score`: that one is
            // still the score the session opened on and would name staves that no longer exist, which
            // `reconcilingAuthoredHidden` would then write into the row as provenance (review Minor 1, round 1).
            guard let self, let score = host?.editedScore else {
                // The queued writes go with the release: they were stamped against a score this process no longer
                // has, and the only path that empties `editedScore` is the revert, which reloads everything from
                // disk immediately afterwards.
                if host?.releasePartMappingHoldIfSettled() == true {
                    self?.discardDeferredPreferenceWrites()
                }
                return
            }
            Task {
                await self.reloadPreferencesAfterPartRemap(
                    authoredHiddenStaves: score.authoredHiddenStaffAddresses,
                    // The release happens HERE, on the far side of the re-read — never when the Editor's save
                    // finished. It answers `false` if a later part edit has raised the flag again, and that edit's
                    // own reload is then the one that releases.
                    liftHold: { [weak host] in host?.releasePartMappingHoldIfSettled() ?? false },
                )
            }
        }
        // Catch a hold raised before this closure existed. The App wires `onPartEditApplied` at `.onAppear`, this
        // runs from `.task`, and until it does the settle calls the default no-op — so a part edit landing in
        // between would raise a flag nothing could ever lower. Reaching that window needs the instruments sheet
        // before the screen's own `.task` has run, which the editing chrome's lifecycle makes hard rather than
        // impossible; one line here removes the question. It is a no-op in the normal case (nothing raised), and
        // correctly declines while a part edit really is outstanding.
        host.releasePartMappingHoldIfSettled()
    }
}
