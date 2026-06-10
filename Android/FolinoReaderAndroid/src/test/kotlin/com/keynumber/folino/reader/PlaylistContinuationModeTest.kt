package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaylistContinuationModeTest {
    @Test fun wire_roundTrips_eachCase() {
        for (mode in PlaylistContinuationMode.entries) {
            assertEquals(mode, PlaylistContinuationMode.fromWire(mode.wire))
        }
    }

    @Test fun wire_values_matchIosRawValues() {
        assertEquals("off", PlaylistContinuationMode.OFF.wire)
        assertEquals("playThrough", PlaylistContinuationMode.PLAY_THROUGH.wire)
        assertEquals("loopPlaylist", PlaylistContinuationMode.LOOP_PLAYLIST.wire)
    }

    @Test fun fromWire_unknown_defaultsToPlayThrough() {
        assertEquals(PlaylistContinuationMode.PLAY_THROUGH, PlaylistContinuationMode.fromWire(null))
        assertEquals(PlaylistContinuationMode.PLAY_THROUGH, PlaylistContinuationMode.fromWire("bogus"))
    }
}
