import Domain
import ScoreUI

// MARK: - PlaybackMixerHost conformance

extension ReaderViewModel: PlaybackMixerHost {
    /// Required by `PlaybackMixerHost`. Reads through `playbackSession` so `PlaybackMixerModel` can check whether
    /// playback is active (e.g. to decide whether to show a mute indicator).
    var isPlaying: Bool {
        playbackSession.isPlaying
    }

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
}
