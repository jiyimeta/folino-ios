package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [retiredHandlesToRelease] and [isScoreHandleHeld] — who frees the score handle a resync displaced, and when.
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
        // Why the list stays bounded by what the audio side is really using rather than growing with the session:
        // only the handles it names are refused, and every other retirement drains on the first compute after it.
        val (release, keep) = retiredHandlesToRelease(listOf(1L, 2L, 3L), currentHandle = 9L) { it == 2L }
        assertEquals(listOf(1L, 3L), release)
        assertEquals(listOf(2L), keep)
    }

    @Test
    fun `a handle retired after the swap is published is still eligible`() {
        // The fix-round-2 regression. `replaceScoreHandle` publishes the incoming handle and only then records the
        // one it displaced; a drain running in between sees the NEW handle as current, so the superseded entry must
        // not be mistaken for the live one and dropped. Retiring before publishing put the old handle in the list
        // while `_scoreHandle.value` still equalled it, and the "never free the live handle" rule below discarded it
        // permanently — no crash, just the leak this machinery exists to prevent.
        val superseded = 1L
        val incoming = 2L
        val (release, keep) = retiredHandlesToRelease(listOf(superseded), currentHandle = incoming) { false }
        assertEquals(listOf(superseded), release)
        assertTrue(keep.isEmpty())
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

    // MARK: - What counts as "the audio side is still holding it" ([isScoreHandleHeld])

    @Test
    fun `the score the engine prepared is held`() {
        assertTrue(isScoreHandleHeld(1L, preparedHandle = 1L, pendingHandles = emptyList()))
        assertFalse(isScoreHandleHeld(2L, preparedHandle = 1L, pendingHandles = emptyList()))
    }

    @Test
    fun `a prepare still in flight holds its handle before the engine ever names it`() {
        // The window the claim exists for: `preparePlayback` captures the handle, suspends waiting for the playback
        // service to bind, and only names it as prepared afterwards. A resync landing inside that window would
        // otherwise see nothing holding it and free the score the coroutine is about to dereference.
        assertTrue(isScoreHandleHeld(2L, preparedHandle = 1L, pendingHandles = listOf(2L)))
    }

    @Test
    fun `a newer prepare does not release the older one's claim`() {
        // Why the claim is a list and not a single slot: a second prepare for a newer handle must not unpin the
        // handle an earlier coroutine is still suspended on.
        assertTrue(isScoreHandleHeld(2L, preparedHandle = null, pendingHandles = listOf(2L, 3L)))
        assertTrue(isScoreHandleHeld(3L, preparedHandle = null, pendingHandles = listOf(2L, 3L)))
    }

    @Test
    fun `nothing prepared and nothing pending holds nothing`() {
        assertFalse(isScoreHandleHeld(1L, preparedHandle = null, pendingHandles = emptyList()))
    }
}
