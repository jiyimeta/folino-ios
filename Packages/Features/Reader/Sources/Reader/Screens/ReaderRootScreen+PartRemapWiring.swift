import Domain

extension ReaderRootScreen {
    /// Wires the part-remap half of the editing seam onto `host`, from the same `.task` block that fills its other
    /// providers. Split into its own file — rather than inlined there — for the same reason `wireRevertReload` is:
    /// to keep `ReaderRootScreen`'s primary declaration under SwiftLint's `type_body_length` budget.
    ///
    /// Two halves. The store is taught to hold its writes while the host says a migration is unsettled, and the
    /// reload is wired to re-read the row and release what was held once it settles.
    func wirePartRemapReload(host: ReaderEditingHost, viewModel: ReaderViewModel) {
        viewModel.setPreferenceMigrationPendingProvider { [weak host] in
            host?.isPartMappingPending ?? false
        }
        host.requestReloadAfterPartRemap = { [weak viewModel, weak host] in
            guard let viewModel else { return }
            // The POST-edit score — the one whose part numbering the row now describes. `loadState.score` is still
            // the score the session opened on and would name staves that no longer exist, which
            // `reconcilingAuthoredHidden` would then write into the row as provenance. There is no safe fallback to
            // it, so no score means nothing to do (review Minor 1).
            guard let score = host?.editedScore else { return }
            Task {
                await viewModel.reloadPreferencesAfterPartRemap(
                    authoredHiddenStaves: score.authoredHiddenStaffAddresses,
                    // The App has already lowered the flag by the time this runs — the Editor drops it before it
                    // asks for the reload, precisely so the deferred writes are not held again by their own
                    // release. Reading it here rather than assuming keeps a second, still-unsettled part edit in
                    // charge of when they actually go.
                    liftHold: { [weak host] in !(host?.isPartMappingPending ?? false) },
                )
            }
        }
    }
}
