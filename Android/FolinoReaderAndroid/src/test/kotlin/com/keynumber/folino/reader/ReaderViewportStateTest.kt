package com.keynumber.folino.reader

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for [ReaderViewportState] — the snapshot-state holder the three reader surfaces share.
 *
 * The zoom tests are the regression for the bug this replaced: the old surfaces wrote the focal
 * correction back through `ScrollState.scrollTo`, which clamped against a `maxValue` describing the
 * PREVIOUS frame's layout. Zooming in pinned the offset to a stale upper bound and the anchor slid to
 * the top-left. Clamping against the extent at the new scale is what fixes it.
 */
class ReaderViewportStateTest {

    /** A 1000x800 viewport over content that is 1000x4000 px at scale 1, with no padding. */
    private fun state(
        deferRaster: Boolean = false,
        underfillY: ViewportUnderfill = ViewportUnderfill.START,
    ) = ReaderViewportState(deferRaster, ViewportUnderfill.START, underfillY).apply {
        geometry = ViewportGeometry(
            viewportWidthPx = 1000f,
            viewportHeightPx = 800f,
            unitContentWidthPx = 1000f,
            unitContentHeightPx = 4000f,
        )
    }

    @Test fun applyPan_movesOppositeTheFinger() {
        val s = state()
        s.snapOffsetY(500f)
        s.applyPan(Offset(0f, -120f)) // finger travels up ⇒ content scrolls down
        assertEquals(620f, s.offsetY, 0.01f)
    }

    @Test fun applyPan_clampsAtTheTop() {
        val s = state()
        s.snapOffsetY(40f)
        s.applyPan(Offset(0f, 400f))
        assertEquals(0f, s.offsetY, 0.01f)
    }

    @Test fun applyPan_doesNotMoveHorizontallyAtFitWidth() {
        val s = state()
        s.applyPan(Offset(-300f, 0f))
        assertEquals(0f, s.offsetX, 0.01f)
    }

    @Test fun applyZoom_holdsTheCentroid() {
        val s = state()
        s.snapOffsetY(600f)
        val centroid = Offset(500f, 300f)
        val documentY = (s.offsetY + centroid.y) / s.scale
        s.applyZoom(zoomFactor = 2f, centroid = centroid)
        assertEquals(2f, s.scale, 0.001f)
        assertEquals(centroid.y, s.scale * documentY - s.offsetY, 0.05f)
    }

    @Test fun applyZoom_doesNotCollapseToTheTopLeft() {
        // The regression: zooming in near the bottom of a long score must not snap the viewport home.
        val s = state()
        s.snapOffsetY(3000f)
        s.applyZoom(zoomFactor = 1.5f, centroid = Offset(500f, 400f))
        assert(s.offsetY > 3000f) { "expected the offset to grow with the zoom, was ${s.offsetY}" }
    }

    @Test fun applyZoom_clampsIntoTheNewExtent() {
        // Zoom in, ride to the very bottom, then zoom back out: the offset has to come back inside the
        // shrunken extent rather than sitting past its new end.
        val s = state()
        s.applyZoom(zoomFactor = 4f, centroid = Offset(500f, 400f))
        s.snapOffsetY(Float.MAX_VALUE) // clamps to the maximum at scale 4: 16000 - 800
        assertEquals(15200f, s.offsetY, 0.01f)
        s.applyZoom(zoomFactor = 0.5f, centroid = Offset(500f, 400f))
        assertEquals(2f, s.scale, 0.001f)
        assertEquals(7200f, s.offsetY, 0.01f) // the maximum at scale 2: 8000 - 800
    }

    @Test fun underfillCenter_centersShortContent() {
        val s = ReaderViewportState(false, ViewportUnderfill.START, ViewportUnderfill.CENTER).apply {
            geometry = ViewportGeometry(
                viewportWidthPx = 1000f,
                viewportHeightPx = 800f,
                unitContentWidthPx = 3000f,
                unitContentHeightPx = 400f,
            )
        }
        s.snapOffsetY(0f)
        assertEquals(-200f, s.offsetY, 0.01f)
    }

    @Test fun deferRaster_holdsTheRasterScaleUntilSettled() {
        val s = state(deferRaster = true)
        s.applyZoom(zoomFactor = 2f, centroid = Offset(500f, 400f))
        assertEquals(2f, s.scale, 0.001f)
        assertEquals(1f, s.rasterScale, 0.001f)
        s.settleRaster()
        assertEquals(2f, s.rasterScale, 0.001f)
    }

    @Test fun withoutDeferRaster_theRasterScaleTracksTheScale() {
        val s = state(deferRaster = false)
        s.applyZoom(zoomFactor = 2f, centroid = Offset(500f, 400f))
        assertEquals(2f, s.rasterScale, 0.001f)
    }

    @Test fun reset_returnsToFitAndOrigin() {
        val s = state()
        s.snapOffsetY(900f)
        s.applyZoom(zoomFactor = 3f, centroid = Offset(500f, 400f))
        s.reset()
        assertEquals(1f, s.scale, 0.001f)
        assertEquals(1f, s.rasterScale, 0.001f)
        assertEquals(0f, s.offsetX, 0.001f)
        assertEquals(0f, s.offsetY, 0.001f)
    }

    @Test fun shrinkingTheContentReClampsTheOffset() {
        val s = state()
        s.snapOffsetY(3200f) // the maximum at scale 1: 4000 - 800
        s.geometry = s.geometry.copy(unitContentHeightPx = 2000f)
        assertEquals(1200f, s.offsetY, 0.01f) // the new maximum: 2000 - 800
    }
}
