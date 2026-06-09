/// What happens when a score finishes while it was opened as part of a playlist, **and** no per-score repeat is active
/// (per-score `RepeatMode` always takes priority — see `PlaylistPlaybackProgression`). Stored as a single global,
/// sticky `@AppStorage` value under `ReaderGlobalSettingsKey.playlistContinuationMode`; defaults to `.playThrough`.
public enum PlaylistContinuationMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// Stop after the current score.
    case off
    /// Advance through the playlist, then stop after the last score. The default.
    case playThrough
    /// Advance through the playlist; after the last score, wrap to the first and keep going.
    case loopPlaylist
}
