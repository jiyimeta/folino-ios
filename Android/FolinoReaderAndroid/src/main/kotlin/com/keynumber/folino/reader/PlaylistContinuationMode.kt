package com.keynumber.folino.reader

/**
 * Playlist continuation mode. Mirrors iOS `Domain.PlaylistContinuationMode`; [wire] equals the iOS
 * rawValue so the value round-trips across the JNI bridge (`FolinoReaderJNI.nativePlaylistNextAction`)
 * and the cross-platform DataStore export. This is a wire/UI enum only — the advance decision lives in
 * shared Swift (`PlaylistPlaybackProgression`), never re-implemented here.
 *
 * The unknown/`null` fallback is [PLAY_THROUGH], matching the iOS default and the DataStore default.
 */
enum class PlaylistContinuationMode(val wire: String) {
    OFF("off"),
    PLAY_THROUGH("playThrough"),
    LOOP_PLAYLIST("loopPlaylist");

    companion object {
        fun fromWire(raw: String?): PlaylistContinuationMode =
            entries.firstOrNull { it.wire == raw } ?: PLAY_THROUGH
    }
}

/**
 * One position in the playlist the Reader is currently reading from: everything the Reader has to hand
 * back to the host to move there.
 *
 * A named type rather than a `Pair`/`Triple` because it is exactly the set of per-score fields an
 * auto-advance must carry over together. When this was a `(id, localFileName)` pair the title had
 * nowhere to ride, so it stayed at whatever the Reader was originally navigated to and the app bar went
 * on naming the score that had just finished. A field added here is a field the advance path cannot
 * silently forget.
 *
 * The Reader never resolves any of these itself — the host supplies them, as it does everywhere else in
 * this screen.
 */
data class PlaylistEntry(
    val id: String,
    /** The record's real on-disk file name (Room `local_file_name`), e.g. a PDF import's `<id>.pdf`. */
    val localFileName: String,
    /** Display title for the app bar. */
    val title: String,
)
