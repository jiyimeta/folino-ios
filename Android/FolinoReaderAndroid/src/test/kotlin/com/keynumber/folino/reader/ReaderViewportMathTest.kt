package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for the pure viewport math shared by the three reader surfaces.
 *
 * The focal tests assert the property that matters rather than the formula: the document point sitting
 * under the pinch centroid must land on the same screen pixel after the zoom step. Screen position of a
 * document point `d` (document px at scale 1) is `pad + scale * d - offset`, where `pad` is fixed padding
 * that does not scale with zoom.
 */
class ReaderViewportMathTest {

    private fun screenX(documentPx: Float, scale: Float, offset: Float, pad: Float = 0f): Float =
        pad + scale * documentPx - offset

    @Test fun axisContentPx_scalesContentButNotThePad() {
        assertEquals(2400f, axisContentPx(unitContentPx = 1000f, fixedPadPx = 400f, scale = 2f), 0.001f)
    }

    @Test fun clamp_contentLargerThanViewport_staysInRange() {
        assertEquals(0f, clampAxisOffset(-50f, 2000f, 800f, ViewportUnderfill.START), 0.001f)
        assertEquals(700f, clampAxisOffset(700f, 2000f, 800f, ViewportUnderfill.START), 0.001f)
        assertEquals(1200f, clampAxisOffset(5000f, 2000f, 800f, ViewportUnderfill.START), 0.001f)
    }

    @Test fun clamp_contentSmallerThanViewport_startPinsToZero() {
        assertEquals(0f, clampAxisOffset(300f, 500f, 800f, ViewportUnderfill.START), 0.001f)
    }

    @Test fun clamp_contentSmallerThanViewport_centerReturnsHalfTheGapNegated() {
        // Content 500 px inside an 800 px viewport: a 150 px lead-in on each side. Offset is a scroll
        // position, so the lead-in is a NEGATIVE offset (translation = -offset pushes content forward).
        assertEquals(-150f, clampAxisOffset(300f, 500f, 800f, ViewportUnderfill.CENTER), 0.001f)
    }

    @Test fun focal_holdsTheCentroid_withoutPad() {
        val scale0 = 2f
        val offset0 = 340f
        val centroid = 260f
        val ratio = 1.25f
        val documentPx = (offset0 + centroid) / scale0
        val offset1 = focalAdjustedOffset(offset0, centroid, ratio)
        assertEquals(centroid, screenX(documentPx, scale0 * ratio, offset1), 0.01f)
    }

    @Test fun focal_holdsTheCentroid_withLeadingPad() {
        val pad = 48f
        val scale0 = 1.5f
        val offset0 = 200f
        val centroid = 410f
        val ratio = 0.8f
        val documentPx = (offset0 + centroid - pad) / scale0
        val offset1 = focalAdjustedOffset(offset0, centroid, ratio, pad)
        assertEquals(centroid, screenX(documentPx, scale0 * ratio, offset1, pad), 0.01f)
    }

    @Test fun coerceReaderScale_clampsToOneThroughEight() {
        assertEquals(1f, coerceReaderScale(0.25f), 0.001f)
        assertEquals(3.5f, coerceReaderScale(3.5f), 0.001f)
        assertEquals(8f, coerceReaderScale(12f), 0.001f)
    }
}
