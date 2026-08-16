import Domain
import ScoreUI

// MARK: - PlaybackMixerHost conformance

extension ReaderViewModel: PlaybackMixerHost {
    /// Required by `PlaybackMixerHost`. Reads through `playbackSession` so `PlaybackMixerModel` can forward volume,
    /// mute, and program changes to the active controller without holding a direct reference to the session.
    var playbackController: (any PlaybackController)? {
        playbackSession.controller
    }
}

// MARK: - ScoreInfoEditing conformance

extension ReaderViewModel: ScoreInfoEditing {
    func loadFileMetadata(for item: ScoreItem) async -> ScoreFileMetadata? {
        try? await metadataReader.readMetadata(for: item)
    }

    func saveMetadata(_ item: ScoreItem, fields: EditableScoreInfo) async {
        guard let n = fields.normalized() else { return }
        var updated = item
        updated.title = n.title
        updated.subtitle = n.subtitle
        updated.composer = n.composer
        updated.arranger = n.arranger
        updated.lyricist = n.lyricist
        updated.copyright = n.copyright
        do {
            try await repository.saveScoreItem(updated)
            scoreItem = updated
        } catch {
            // Non-fatal: keep the in-memory item; no Reader error banner yet.
        }
    }

    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) async {
        // Errors are swallowed, matching `saveMetadata` right above: the Reader has no error banner yet, and the
        // score on disk is untouched when the store throws.
        guard let reverted = try? await originalStore.revertToOriginal(
            item,
            restoringScoreInfo: restoringScoreInfo,
        ) else { return }
        try? await repository.saveScoreItem(reverted)
        // The file on disk already changed above, inside `originalStore.revertToOriginal`; what this guards is the
        // in-memory swap and `load()` just below — tearing down or swapping a live engine's render thread out from
        // under it is this repo's known crash class. Mirrors `advance(to:)` and `adoptEditedScore`, and the
        // Editor's own revert path (which releases explicitly for the same reason). This entry point is reached
        // from the score-info sheet, opened from either the Reader or the Library, so it had no sibling to copy
        // this from directly (Important 3 review fix).
        await playbackSession.releaseEngine()
        // Unlike `saveMetadata` above, this assigns unconditionally even though the row save just above can throw
        // and is swallowed. By this point the FILE on disk genuinely is the original — the store's write already
        // happened — so the UI must show it regardless of whether the row write landed; a stale row here is the
        // same benign, self-correcting mismatch the design doc's "Atomicity" section already accepts elsewhere.
        scoreItem = reverted
        await load()
    }
}
