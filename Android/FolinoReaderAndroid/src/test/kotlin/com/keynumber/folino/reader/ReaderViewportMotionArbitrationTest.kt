package com.keynumber.folino.reader

import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.ui.geometry.Offset
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression tests for the arbitration between a programmatic viewport animation and whatever moves the
 * viewport next.
 *
 * `ScrollState.animateScrollTo` used to get this for free: it ran under `ScrollableState`'s `MutatorMutex`,
 * so a drag arriving at user-input priority cancelled the in-flight programmatic scroll. [ReaderViewportState]
 * has no mutex — the user-input path ([ReaderViewportState.applyPan]) is synchronous and cannot take a
 * suspending lock — so a per-axis generation counter plays that role instead. Without it, grabbing the score
 * during a playback re-pin left the spring writing over the finger for the rest of its trajectory.
 *
 * Driven by a [BroadcastFrameClock] pumped by hand rather than by a test dispatcher: `kotlinx-coroutines-test`
 * is not on this module's test classpath, and an animation needs a frame clock either way.
 *
 * These deliberately never `join()` the animation coroutine — they assert on the offset and then cancel. An
 * un-arbitrated animation does not finish inside the pumped frames, so joining it would hang the suite rather
 * than fail it, and a regression test that hangs is a regression test nobody can read the output of.
 */
class ReaderViewportMotionArbitrationTest {

    /** A 1000x800 viewport over content that is 1000x4000 px at scale 1, with no padding. */
    private fun state() = ReaderViewportState(
        deferRaster = false,
        underfillX = ViewportUnderfill.START,
        underfillY = ViewportUnderfill.START,
    ).apply {
        geometry = ViewportGeometry(
            viewportWidthPx = 1000f,
            viewportHeightPx = 800f,
            unitContentWidthPx = 1000f,
            unitContentHeightPx = 4000f,
        )
    }

    /** Pump [frames] display frames, letting the animation coroutine run to its next suspension each time. */
    private suspend fun BroadcastFrameClock.pump(frames: Int, startFrame: Int = 0) {
        repeat(frames) { i ->
            yield()
            sendFrame((startFrame + i) * FRAME_NANOS)
            yield()
        }
    }

    /** Assert the spring is genuinely mid-flight, so the checks below cannot pass vacuously. */
    private fun assertUnderWay(offset: Float, target: Float) {
        assertTrue("expected the animation to be under way, was $offset", offset > 1f)
        assertTrue("expected the animation to still have travel left, was $offset", offset < target - 1f)
    }

    @Test fun interruptMotion_stopsAnInFlightAutoFollowAnimation() = runBlocking {
        val s = state()
        val clock = BroadcastFrameClock()
        val job = launch(clock + Dispatchers.Unconfined) { s.animateOffsetYTo(3000f) }

        clock.pump(frames = 6)
        val whenInterrupted = s.offsetY
        assertUnderWay(whenInterrupted, 3000f)

        s.interruptMotion()
        clock.pump(frames = 10, startFrame = 6)

        assertEquals("the spring kept writing after being interrupted", whenInterrupted, s.offsetY, 0.001f)
        job.cancel()
    }

    @Test fun aFingerPanSurvivesAnInFlightAutoFollowAnimation() = runBlocking {
        val s = state()
        val clock = BroadcastFrameClock()
        val job = launch(clock + Dispatchers.Unconfined) { s.animateOffsetYTo(3000f) }

        clock.pump(frames = 6)
        assertUnderWay(s.offsetY, 3000f)

        // What the gesture loop does on the first down: claim the axes, then pan.
        s.interruptMotion()
        s.snapOffsetY(120f)
        clock.pump(frames = 10, startFrame = 6)

        assertEquals("the re-pin overwrote the reader's own position", 120f, s.offsetY, 0.001f)
        job.cancel()
    }

    @Test fun aPanStandsDownAnAnimationThatStartedMidGesture() = runBlocking {
        val s = state()
        val clock = BroadcastFrameClock()
        // The gesture is already under way — the loop claimed the axes when the finger landed.
        s.interruptMotion()
        // Auto-follow then restarts DURING the gesture and re-pins with a fresh generation. Claiming the axes
        // once, at the first down, is not enough: whatever starts after that claim outranks the finger for the
        // rest of its trajectory. `ScrollState`'s `MutatorMutex` held user-input priority for the whole
        // gesture, not just its first frame.
        val job = launch(clock + Dispatchers.Unconfined) { s.animateOffsetYTo(3000f) }
        clock.pump(frames = 6)
        assertUnderWay(s.offsetY, 3000f)

        // The finger is still down and still moving. It must win.
        s.applyPan(Offset(0f, -120f))
        val whereTheFingerPutIt = s.offsetY
        clock.pump(frames = 10, startFrame = 6)

        assertEquals("the re-pin wrote over the finger", whereTheFingerPutIt, s.offsetY, 0.001f)
        job.cancel()
    }

    @Test fun aPinchStandsDownAnAnimationThatStartedMidGesture() = runBlocking {
        val s = state()
        val clock = BroadcastFrameClock()
        s.interruptMotion()
        val job = launch(clock + Dispatchers.Unconfined) { s.animateOffsetYTo(3000f) }
        clock.pump(frames = 6)
        assertUnderWay(s.offsetY, 3000f)

        // A pinch moves the offsets too, through the focal correction, so it has to claim the axes for the
        // same reason a pan does. This is the horizontal surface's reported bug: the auto-follow effect was
        // keyed on the zoom, so every frame of a fast pinch restarted it and launched a fresh re-pin.
        s.applyZoom(zoomFactor = 1.5f, centroid = Offset(500f, 400f))
        val whereThePinchPutIt = s.offsetY
        clock.pump(frames = 10, startFrame = 6)

        assertEquals("the re-pin wrote over the pinch", whereThePinchPutIt, s.offsetY, 0.001f)
        job.cancel()
    }

    @Test fun aYAnimationIsNotCancelledByAnXAnimation() = runBlocking {
        val s = state()
        val clock = BroadcastFrameClock()
        // X has no travel at fit width, so only the Y animation can move anything. The point is that starting
        // the X one must not stand the Y one down — the vertical surface's auto-follow launches both from one
        // coroutine, and a single shared counter would have the second call abort the first.
        val jobs = mutableListOf<Job>()
        jobs += launch(clock + Dispatchers.Unconfined) { s.animateOffsetYTo(3000f) }
        jobs += launch(clock + Dispatchers.Unconfined) { s.animateOffsetXTo(0f) }

        clock.pump(frames = 6)
        val afterX = s.offsetY
        assertTrue("the X animation stood the Y animation down, was $afterX", afterX > 1f)

        clock.pump(frames = 6, startFrame = 6)
        assertTrue("the Y animation stopped advancing", s.offsetY > afterX)

        jobs.forEach { it.cancel() }
    }

    private companion object {
        const val FRAME_NANOS = 16_000_000L
    }
}
