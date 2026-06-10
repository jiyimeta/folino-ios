/// Pure decision for "what to do when a score finishes," given where we are in a playlist, the per-score repeat mode,
/// and the global continuation mode. Shared by the iOS `ReaderViewModel` and the Android reader so both platforms
/// traverse playlists identically.
///
/// Priority ladder (no two-axis truth table): per-score `RepeatMode` is primary — when it is anything other than
/// `.off` the result is always `.stop` (in practice the audio engine loops and never reports end-of-score, so this is
/// belt-and-suspenders). Only when `repeatMode == .off` does `continuation` decide.
public enum PlaylistPlaybackProgression {
    public enum Advance: Hashable, Sendable {
        /// Stop playback at the end of the current score.
        case stop
        /// Reload and auto-play the score at this index in the live ordered playlist.
        case advance(toIndex: Int)
    }

    /// - Parameters:
    ///   - currentIndex: index of the finishing score within the live ordered playlist.
    ///   - count: number of live scores in the playlist.
    ///   - repeatMode: the score's per-score repeat state.
    ///   - continuation: the global playlist-continuation setting.
    public static func nextAction(
        currentIndex: Int,
        count: Int,
        repeatMode: RepeatMode,
        continuation: PlaylistContinuationMode,
    ) -> Advance {
        guard repeatMode == .off else { return .stop }
        guard continuation != .off else { return .stop }
        guard count > 0, currentIndex >= 0, currentIndex < count else { return .stop }

        let next = currentIndex + 1
        if next < count { return .advance(toIndex: next) }
        // At the last score.
        switch continuation {
        case .loopPlaylist: return .advance(toIndex: 0)
        case .playThrough, .off: return .stop
        }
    }
}

extension PlaylistPlaybackProgression {
    /// Wire-friendly form of `nextAction` for the Android JNI bridge: the enums cross as their
    /// `rawValue` strings and the `Advance` result collapses to an `Int` — `-1` for `.stop`, or a
    /// value `>= 0` for `.advance(toIndex:)`. Keeping the rawValue parsing and the result encoding in
    /// shared Domain means both the decision and its wire mapping are unit-tested here on iOS, and the
    /// Android jextract wrapper is a pure delegation (parity — no divergent Kotlin port).
    public static func nextActionWire(
        currentIndex: Int,
        count: Int,
        repeatModeRawValue: String,
        continuationRawValue: String,
    ) -> Int {
        let repeatMode = RepeatMode(rawValue: repeatModeRawValue) ?? .off
        let continuation = PlaylistContinuationMode(rawValue: continuationRawValue) ?? .off
        switch nextAction(
            currentIndex: currentIndex, count: count,
            repeatMode: repeatMode, continuation: continuation,
        ) {
        case .stop: return -1
        case let .advance(toIndex): return toIndex
        }
    }
}
