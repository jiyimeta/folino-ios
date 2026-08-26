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
            guard let viewModel else { return }
            // The POST-edit score — the one whose part numbering the row now describes. `loadState.score` is still
            // the score the session opened on and would name staves that no longer exist, which
            // `reconcilingAuthoredHidden` would then write into the row as provenance. There is no safe fallback to
            // it (review Minor 1, round 1).
            guard let score = host?.editedScore else {
                // Nothing to reconcile against — but the hold MUST still come down, or this Reader would never
                // write the row again for the rest of the session. The queued writes go with it: they were stamped
                // against a score this process no longer has, and the only path that empties `editedScore` is the
                // revert, which reloads everything from disk immediately afterwards.
                if host?.releasePartMappingHoldIfSettled() == true {
                    viewModel.discardDeferredPreferenceWrites()
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
    }
}
