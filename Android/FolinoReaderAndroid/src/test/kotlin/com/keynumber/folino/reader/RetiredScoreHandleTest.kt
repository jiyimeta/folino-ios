package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [retiredHandlesToRelease] — who frees the score handle a resync displaced, and when.
 *
 * `EditSessionRelay` used to call `nativeReleaseScore` on the handle it superseded, which made every remaining
 * holder a use-after-free; SP4 Task 9 moved that ownership to `ReaderViewModel` because the audio engine and the
 * bound `MediaSessionService` hold the same pointer past any window the host can close synchronously. Owning a
 * lifetime means ending it, though, and the first cut of that change never ended it at all — one full parsed
 * `Score` accumulated per resync until the ViewModel died. This predicate is the drain decision that closes that,
 * and these cases are what keep it from regressing in either direction: freeing too early is a crash, freeing
 * never is the leak.
 *
 * `ReaderViewModel(app)` cannot be constructed in this module's JVM test source set — no Robolectric, no Android
 * `Application` (see `RecomputeSkipTest` and `ReaderEditHostTest` for the same constraint) — and the release
 * itself is a JNI call with no library to reach here. That the drain runs only under `layoutMutex`, from a point
 * after the swap has already driven a layout, is structural and belongs to review and the device pass.
 */
class RetiredScoreHandleTest {

    @Test
    fun `a superseded handle nothing holds is freed`() {
        val (release, keep) = retiredHandlesToRelease(listOf(1L), currentHandle = 2L) { false }
        assertEquals(listOf(1L), release)
        assertTrue(keep.isEmpty())
    }

    @Test
    fun `a superseded handle the audio engine still holds waits for the next drain`() {
        // The engine decodes the score into the player and shares the handle with the bound service, so freeing it
        // here would be exactly the use-after-free the ownership change exists to avoid.
        val (release, keep) = retiredHandlesToRelease(listOf(1L), currentHandle = 2L) { it == 1L }
        assertTrue(release.isEmpty())
        assertEquals(listOf(1L), keep)
    }

    @Test
    fun `the engine holding one handle does not pin the others`() {
        // Why the list is bounded at one live retired handle rather than growing with the session: the engine holds
        // at most one score, so at most one entry can ever be refused a release.
        val (release, keep) = retiredHandlesToRelease(listOf(1L, 2L, 3L), currentHandle = 9L) { it == 2L }
        assertEquals(listOf(1L, 3L), release)
        assertEquals(listOf(2L), keep)
    }

    @Test
    fun `the live handle is never freed, and never retried forever`() {
        // Only reachable through a bug upstream. Freeing it would blank the score; keeping it would retry on every
        // compute for the rest of the session, so it is dropped from the list instead.
        val (release, keep) = retiredHandlesToRelease(listOf(5L), currentHandle = 5L) { false }
        assertTrue(release.isEmpty())
        assertTrue(keep.isEmpty())
    }

    @Test
    fun `a null current handle does not stop the drain`() {
        // `load()` clears `_scoreHandle` while retargeting, and a drain that treated "no current score" as a reason
        // to keep everything would strand the list across exactly the transition that produces retired handles.
        val (release, keep) = retiredHandlesToRelease(listOf(1L), currentHandle = null) { false }
        assertEquals(listOf(1L), release)
        assertTrue(keep.isEmpty())
    }

    @Test
    fun `nothing retired releases nothing`() {
        val (release, keep) = retiredHandlesToRelease(emptyList(), currentHandle = 1L) { false }
        assertTrue(release.isEmpty())
        assertTrue(keep.isEmpty())
    }
}
