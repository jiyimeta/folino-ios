package com.keynumber.folino.reader

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the sticky playback-follow suspension state machine ([nextPlaybackFollowSuspended]) —
 * the caller-side set/clear logic that `ReaderAudioViewModel` routes its `isPlaybackFollowSuspended`
 * flag through. `AutoFollowTest` covers the pure [shouldAutoFollow] predicate's instantaneous truth
 * table; this covers the LIFECYCLE that decides its `userInteracting` input.
 *
 * The whole point of the fix is that the suspension is STICKY (session-scoped), not a live
 * gesture-in-progress flag: it persists after the gesture ends and clears only on play-restart or a
 * manual cursor set. Mirrors iOS `ReaderPlaybackSession`'s set/clear rules.
 */
class PlaybackFollowSuspensionTest {

    @Test fun gestureBeginsDuringPlayback_suspends() {
        val next = nextPlaybackFollowSuspended(
            current = false, isPlaying = true, event = PlaybackFollowEvent.ManualViewportChangeBegan,
        )
        assertTrue(next)
    }

    @Test fun gestureBeginsWhilePaused_doesNotSuspend() {
        // A stray gesture while paused/stopped must not leave a suspension that survives into the next
        // play (nothing to follow while paused; the next play re-arms follow regardless).
        val next = nextPlaybackFollowSuspended(
            current = false, isPlaying = false, event = PlaybackFollowEvent.ManualViewportChangeBegan,
        )
        assertFalse(next)
    }

    @Test fun gestureEnds_staysSuspended() {
        // THE regression guard: the old live flag cleared the instant the gesture ended, snapping the
        // page back to the playhead on the next cursor tick. Sticky suspension must survive gesture end.
        val next = nextPlaybackFollowSuspended(
            current = true, isPlaying = true, event = PlaybackFollowEvent.ManualViewportChangeEnded,
        )
        assertTrue(next)
    }

    @Test fun playbackRestart_clearsSuspension() {
        val next = nextPlaybackFollowSuspended(
            current = true, isPlaying = true, event = PlaybackFollowEvent.PlaybackStarted,
        )
        assertFalse(next)
    }

    @Test fun manualCursorSet_clearsSuspension() {
        val next = nextPlaybackFollowSuspended(
            current = true, isPlaying = true, event = PlaybackFollowEvent.ManualCursorSet,
        )
        assertFalse(next)
    }

    @Test fun fullLifecycle_beginPersistsThenClearsOnManualSet() {
        // begin (during playback) → suspended; gesture end → STILL suspended; manual cursor set → cleared.
        var suspended = nextPlaybackFollowSuspended(
            current = false, isPlaying = true, event = PlaybackFollowEvent.ManualViewportChangeBegan,
        )
        assertTrue("gesture begin during playback suspends", suspended)
        suspended = nextPlaybackFollowSuspended(
            current = suspended, isPlaying = true, event = PlaybackFollowEvent.ManualViewportChangeEnded,
        )
        assertTrue("gesture end keeps it suspended (sticky)", suspended)
        suspended = nextPlaybackFollowSuspended(
            current = suspended, isPlaying = true, event = PlaybackFollowEvent.ManualCursorSet,
        )
        assertFalse("manual cursor set clears it", suspended)
    }
}
