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
