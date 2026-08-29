package com.keynumber.folino.editor

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The autosave cadence, on a virtual clock.
 *
 * What is asserted here is coalescing and ordering — the two properties that decide whether a burst of pad taps costs
 * one encode or twenty, and whether leaving a session can outrun the write it owes. The relay's obligation to ASK for
 * each of these is [EditSessionRelayTest]'s subject; this file is only about what the asking then does.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DebouncedAutosaveTest {

    @Test fun aBurstOfEditsCollapsesIntoOneSave() = runTest {
        var saves = 0
        val scope = TestScope(testScheduler)
        val autosave = DebouncedAutosave(scope, delayMillis = 2_000L) { saves += 1 }

        repeat(20) {
            autosave.arm()
            scope.advanceTimeBy(50L)
        }
        assertEquals("nothing may be written while the user is still typing", 0, saves)

        scope.advanceTimeBy(2_001L)
        assertEquals(1, saves)
    }

    @Test fun flushNowWritesImmediatelyAndCancelsThePendingTick() = runTest {
        var saves = 0
        val scope = TestScope(testScheduler)
        val autosave = DebouncedAutosave(scope, delayMillis = 2_000L) { saves += 1 }

        autosave.arm()
        autosave.flushNow()
        assertEquals("a flush is synchronous — the session may be torn down on the next line", 1, saves)

        scope.advanceTimeBy(5_000L)
        assertEquals("the armed tick must not fire a second write after the flush", 1, saves)
    }

    @Test fun flushNowWithNothingArmedStillWrites() = runTest {
        var saves = 0
        val autosave = DebouncedAutosave(TestScope(testScheduler), delayMillis = 2_000L) { saves += 1 }

        autosave.flushNow()

        // The Swift side answers "nothing to do" when the session is clean, so an unconditional call is correct here
        // and keeps this class from tracking dirtiness a second time.
        assertEquals(1, saves)
    }

    @Test fun cancelDropsThePendingWriteWithoutPerformingIt() = runTest {
        var saves = 0
        val scope = TestScope(testScheduler)
        val autosave = DebouncedAutosave(scope, delayMillis = 2_000L) { saves += 1 }

        autosave.arm()
        autosave.cancel()
        scope.advanceTimeBy(5_000L)

        assertEquals(0, saves)
    }

    @Test fun armingAgainAfterASaveStartsAFreshQuietPeriod() = runTest {
        var saves = 0
        val scope = TestScope(testScheduler)
        val autosave = DebouncedAutosave(scope, delayMillis = 2_000L) { saves += 1 }

        autosave.arm()
        scope.advanceTimeBy(2_001L)
        assertEquals(1, saves)

        // A session goes on being edited after its first save; the timer has to rearm rather than latch.
        autosave.arm()
        scope.advanceTimeBy(2_001L)
        assertEquals(2, saves)
    }
}
