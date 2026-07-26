package com.keynumber.folino.reader

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the pure [shouldAutoFollow] predicate — the shared gate for the vertical / horizontal
 * auto-scroll re-pin during playback. Mirrors iOS `readerAutoFollowEnabled` opt-out semantics plus the
 * Task 5 "suspend while the user pans/zooms" extension.
 */
class AutoFollowTest {
    @Test fun disabled_neverFollows() {
        assertFalse(shouldAutoFollow(enabled = false, isPlaying = true, userInteracting = false))
    }

    @Test fun enabled_playing_notInteracting_follows() {
        assertTrue(shouldAutoFollow(enabled = true, isPlaying = true, userInteracting = false))
    }

    @Test fun enabled_playing_interacting_suspendsFollow() {
        assertFalse(shouldAutoFollow(enabled = true, isPlaying = true, userInteracting = true))
    }

    @Test fun enabled_notPlaying_notInteracting_doesNotFollow() {
        // Paused / stopped: nothing to auto-follow via this predicate — the auto-scroll effect's
        // separate paused/manual keep-in-view branch handles bringing a manual seek into view.
        assertFalse(shouldAutoFollow(enabled = true, isPlaying = false, userInteracting = false))
    }
}
