import Domain

extension ReaderRootScreen {
    /// Wires the part-remap half of the editing seam onto `host`, from the same `.task` block that fills its other
    /// providers. Split into its own file — rather than inlined there — for the same reason `wireRevertReload` is:
    /// to keep `ReaderRootScreen`'s primary declaration under SwiftLint's `type_body_length` budget.
    ///
    /// Fires after the Editor's save has already rewritten the persisted row, so all this has to do is make the
    /// in-memory copy agree with it again.
    func wirePartRemapReload(host: ReaderEditingHost, viewModel: ReaderViewModel) {
        host.requestReloadAfterPartRemap = { [weak viewModel, weak host] in
            guard let viewModel else { return }
            // The POST-edit score — the one whose part numbering the migrated row now describes. `loadState.score`
            // is still the score the session opened on and would name staves that no longer exist, which
            // `reconcilingAuthoredHidden` would then write into the row as provenance. Nothing to reconcile against
            // means nothing to do.
            guard let score = host?.editedScore ?? viewModel.loadState.score else { return }
            Task {
                await viewModel.reloadPreferencesAfterPartRemap(
                    authoredHiddenStaves: score.authoredHiddenStaffAddresses,
                )
            }
        }
    }
}
