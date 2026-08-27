package com.keynumber.folino.reader

/**
 * Whether the Reader's playback-cursor auto-follow (auto-scroll in vertical/horizontal mode) should run
 * right now.
 *
 * `enabled` is the user's persistent opt-out (`SettingsPrefs.autoFollow` / `reader.autoFollow.enabled`,
 * default `true` — parity with iOS `readerAutoFollowEnabled`). When `false`, the auto-scroll effect skips
 * entirely: continuous playback no longer re-pins the viewport to the playhead, and a pause never
 * recenters a viewport the reader has scrolled away from.
 *
 * `isPlaying` restricts follow to continuous playback — there is nothing to auto-follow while paused /
 * stopped, so the caller's separate paused/manual keep-in-view path (unconditional on this predicate)
 * is what brings a manual seek on screen.
 *
 * `userInteracting` is the STICKY playback-follow suspension
 * (`ReaderAudioViewModel.isPlaybackFollowSuspended`): set the moment the reader takes manual
 * control of the viewport (scroll / pinch / page-turn) DURING playback, and cleared only when playback
 * (re)starts or the cursor is set manually — NOT when the gesture ends. So an automatic re-pin never
 * fights a reader who has scrolled ahead/back, and the page does not snap to the playhead until they play
 * again or seek. This is the caller-side state that changed from a live gesture flag to a sticky session
 * flag; the predicate itself is unchanged. Mirrors iOS `ReaderPlaybackSession.isPlaybackFollowSuspended`.
 *
 * Pure and Android/Compose-free so it is plain-JVM unit testable (see `AutoFollowTest`). The set/clear
 * lifecycle of the sticky flag lives in `ReaderAudioViewModel` (and is covered by
 * `PlaybackFollowSuspensionTest`); the score surfaces in `ReaderScreen.kt` / `PagedScore.kt` compose this
 * gate with their paused/manual keep-in-view branch to reach the same user-facing behavior as iOS's
 * `Domain.readerShouldFollowPlayback`.
 */
fun shouldAutoFollow(enabled: Boolean, isPlaying: Boolean, userInteracting: Boolean): Boolean =
    enabled && isPlaying && !userInteracting

/**
 * Events that drive the sticky playback-follow suspension (`ReaderAudioViewModel.isPlaybackFollowSuspended`).
 * See [nextPlaybackFollowSuspended] for the transition table.
 */
enum class PlaybackFollowEvent {
    /** A scroll / pinch / page-turn gesture BEGAN. Suspends follow only while playing. */
    ManualViewportChangeBegan,

    /**
     * The gesture ENDED (fingers lifted). Deliberately a NO-OP — the suspension is sticky, so it must
     * NOT clear here. This is the exact regression the fix targets: the old live flag cleared on gesture
     * end, which snapped the page straight back to the playhead on the next cursor tick.
     */
    ManualViewportChangeEnded,

    /** Playback (re)entered PLAYING — re-arm auto-follow. */
    PlaybackStarted,

    /** The cursor was set manually (tap-seek / measure-step / seek bar / rehearsal / jump-to-start). */
    ManualCursorSet,
}

/**
 * Pure transition for the sticky playback-follow suspension: given the [current] suspended state, whether
 * playback [isPlaying], and an [event], returns the next suspended state.
 *
 * The suspension is SET only by a manual viewport change that begins WHILE playing, and CLEARED only by a
 * playback (re)start or a manual cursor set — never by the gesture merely ending. Mirrors iOS
 * `ReaderPlaybackSession`'s set/clear rules. Kept Android/Compose-free so it is plain-JVM unit testable
 * (see `PlaybackFollowSuspensionTest`); `ReaderAudioViewModel` routes its flag mutations through it.
 */
fun nextPlaybackFollowSuspended(
    current: Boolean,
    isPlaying: Boolean,
    event: PlaybackFollowEvent,
): Boolean = when (event) {
    // A gesture that begins while not playing must not leave a suspension that survives into the next
    // play (the next play re-arms follow anyway), so gate the SET on isPlaying.
    PlaybackFollowEvent.ManualViewportChangeBegan -> if (isPlaying) true else current
    PlaybackFollowEvent.ManualViewportChangeEnded -> current
    PlaybackFollowEvent.PlaybackStarted -> false
    PlaybackFollowEvent.ManualCursorSet -> false
}
