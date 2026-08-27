import Domain

extension ReaderRootScreen {
    /// Wires the part-remap half of the editing seam onto `host`, from the same `.task` block that fills its other
    /// providers. Split into its own file — rather than inlined there — for the same reason `wireRevertReload` is:
    /// to keep `ReaderRootScreen`'s primary declaration under SwiftLint's `type_body_length` budget.
    ///
    /// Two halves. The store is taught to hold its writes while the host says a migration is unsettled, and the
    /// reload is wired to re-read the row, release the hold, and let what was held go — in that order.
    func wirePartRemapReload(host: ReaderEditingHost, viewModel: ReaderViewModel) {
        viewModel.setPreferenceMigrationPendingProvider { [weak host] in
            host?.isPartMappingPending ?? false
        }
        host.requestReloadAfterPartRemap = { [weak viewModel, weak host] in
            // Two ways there is nothing to reload — this Reader is already gone, or the editing session no longer
            // has a score — and BOTH have to release. This closure is the only thing that ever lowers the flag, so
            // a bail that returns without it leaves a surviving host stuck at `isPartMappingPending == true` and
            // the next Reader on it never persists its preferences row again (round-3 Important). Hence one guard
            // covering both, with the release above everything.
            //
            // `editedScore` is the POST-edit score, and there is no safe fallback to `loadState.score`: that one is
            // still the score the session opened on and would name staves that no longer exist, which
            // `reconcilingAuthoredHidden` would then write into the row as provenance (review Minor 1, round 1).
            guard let viewModel, let score = host?.editedScore else {
                // The queued writes go with the release: they were stamped against a score this process no longer
                // has, and the only path that empties `editedScore` is the revert, which reloads everything from
                // disk immediately afterwards.
                if host?.releasePartMappingHoldIfSettled() == true {
                    viewModel?.discardDeferredPreferenceWrites()
                }
                return
            }
            Task {
                await viewModel.reloadPreferencesAfterPartRemap(
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
