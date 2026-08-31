// PARITY(macos): extends `ReaderRootScreen` — see the marker on that file for what Ⅳ's Mac reading surface needs.

#if os(iOS)
import Domain

extension ReaderRootScreen {
    /// Wires the revert half of the editing seam onto `host`, from the same `.task` block that fills its other
    /// providers (`sourceScoreProvider`, `hiddenStavesProvider`, …). Split into its own file — rather than inlined
    /// there — to keep `ReaderRootScreen`'s primary declaration under SwiftLint's `type_body_length` budget.
    func wireRevertReload(host: ReaderEditingHost, viewModel: ReaderViewModel) {
        // The Editor cannot see the ink; only "anchored to the notation" counts, not ink pinned to a PDF page, which
        // a revert of the notation never touches.
        host.hasMusicalAnnotationsProvider = { [weak viewModel] in
            viewModel?.annotationDrawings.contains { drawing in
                if case .musical = drawing.kind {
                    true
                } else {
                    false
                }
            } ?? false
        }
        host.requestReloadAfterRevert = { [weak viewModel, weak host] item in
            guard let viewModel else { return }
            Task {
                // Stop first: the file under the audio engine is about to change, and this repo has a history of
                // crashes from tearing down or swapping under a live render thread (mirrors `advance(to:)`).
                await viewModel.playbackSession.releaseEngine()
                viewModel.scoreItem = item
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
                    viewModel.pdfPlayback = .idle
                }
                await viewModel.load()
            }
        }
    }
}
#endif
