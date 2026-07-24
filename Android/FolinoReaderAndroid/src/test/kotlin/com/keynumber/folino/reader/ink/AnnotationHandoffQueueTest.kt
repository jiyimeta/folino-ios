package com.keynumber.folino.reader.ink

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for [AnnotationHandoffQueue] — the wet→dry ink handoff bookkeeping.
 *
 * The regression it exists to prevent: retiring a finished wet stroke before the dry layer has painted its
 * committed counterpart leaves nobody drawing the stroke, so the ink blinks out the instant the finger lifts.
 */
class AnnotationHandoffQueueTest {
    /** Stand-in for a committed `DrawingAnchorWire`; the queue only ever compares these by identity. */
    private class Drawing(val name: String)

    @Test fun retainedStrokeSurvivesUntilTheDryLayerPaintsIt() {
        val queue = AnnotationHandoffQueue<Drawing>()
        var released = 0
        val committed = queue.retain { released++ }
        val drawing = Drawing("just drawn")

        // Capture resolved, but the dry layer has not painted it yet — the wet copy must stay.
        committed(drawing)
        assertEquals(0, released)

        // A dry frame built from an older drawing list must not release it either: the dry overlay
        // repaints for reflow/zoom while the commit is still in flight.
        queue.onDryRendered(listOf(Drawing("older")))
        assertEquals(0, released)

        queue.onDryRendered(listOf(Drawing("older"), drawing))
        assertEquals(1, released)
        assertEquals(0, queue.retainedCount)
    }

    @Test fun strokeThatDidNotAnchorIsReleasedImmediately() {
        val queue = AnnotationHandoffQueue<Drawing>()
        var released = 0
        val committed = queue.retain { released++ }

        // Nothing will ever render it, so holding the wet copy would leave ink that isn't persisted.
        committed(null)
        assertEquals(1, released)
        assertEquals(0, queue.retainedCount)
    }

    @Test fun eachStrokeIsReleasedOnlyOnce() {
        val queue = AnnotationHandoffQueue<Drawing>()
        var released = 0
        val committed = queue.retain { released++ }
        val drawing = Drawing("a")
        committed(drawing)

        queue.onDryRendered(listOf(drawing))
        queue.onDryRendered(listOf(drawing))
        queue.releaseAll()
        assertEquals(1, released)
    }

    @Test fun onlyTheStrokesTheDryFramePaintedAreReleased() {
        val queue = AnnotationHandoffQueue<Drawing>()
        var releasedA = 0
        var releasedB = 0
        val committedA = queue.retain { releasedA++ }
        val committedB = queue.retain { releasedB++ }
        val a = Drawing("a")
        val b = Drawing("b")
        committedA(a)
        committedB(b)

        queue.onDryRendered(listOf(a))
        assertEquals(1, releasedA)
        assertEquals(0, releasedB)
        assertEquals(1, queue.retainedCount)
    }

    @Test fun releaseAllDropsEveryRetainedStroke() {
        val queue = AnnotationHandoffQueue<Drawing>()
        var released = 0
        queue.retain { released++ }.invoke(Drawing("committed"))
        queue.retain { released++ } // still awaiting its capture result

        // The camera moved: retained copies are frozen at the transform captured when the stroke
        // finished, so they must go rather than sit misplaced over the reflowed score.
        queue.releaseAll()
        assertEquals(2, released)
        assertEquals(0, queue.retainedCount)
    }

    @Test fun captureResolvingAfterReleaseAllDoesNotResurrectTheStroke() {
        val queue = AnnotationHandoffQueue<Drawing>()
        var released = 0
        val committed = queue.retain { released++ }
        queue.releaseAll()
        assertEquals(1, released)

        val drawing = Drawing("late")
        committed(drawing)
        queue.onDryRendered(listOf(drawing))
        assertEquals(1, released)
        assertEquals(0, queue.retainedCount)
    }
}
