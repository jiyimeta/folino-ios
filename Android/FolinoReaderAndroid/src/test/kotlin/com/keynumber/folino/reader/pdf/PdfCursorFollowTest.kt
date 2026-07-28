package com.keynumber.folino.reader.pdf

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for [PdfCursorFollow] — the bridge between the vertical PDF surface's WORLD space (raster pixels, where
 * the shared Swift projection hands the cursor back) and its SCROLL space (what
 * `FolinoReaderJNI.nativeScrollOffsetKeepingInView` / `…PinningSystemTop` are given as `targetMin` / `targetMax`).
 *
 * The asymmetry between the two axes is the thing worth pinning: the top pad sits OUTSIDE the page `Column`'s
 * `graphicsLayer`, so it is a FIXED leading offset that does not scale with zoom, while everything inside that layer
 * does. Getting that backwards is invisible in review and shows up on-device as auto-follow settling a little further
 * off the more the reader has zoomed in.
 */
class PdfCursorFollowTest {

    private val eps = 1e-4f

    @Test fun verticalSpan_atUnitZoom_isTheWorldSpanOffsetByThePad() {
        val span = PdfCursorFollow.verticalSpan(worldTop = 200f, worldHeight = 60f, zoom = 1f, topPadPx = 42f)
        assertEquals(242f, span.min, eps)
        assertEquals(302f, span.max, eps)
    }

    @Test fun verticalSpan_scalesTheWorldSpanButNotThePad() {
        val span = PdfCursorFollow.verticalSpan(worldTop = 200f, worldHeight = 60f, zoom = 2f, topPadPx = 42f)
        assertEquals(442f, span.min, eps)
        assertEquals(562f, span.max, eps)
    }

    /** Zooming OUT after a raster settle (live < raster) is the same rule, not a special case. */
    @Test fun verticalSpan_handlesZoomBelowOne() {
        val span = PdfCursorFollow.verticalSpan(worldTop = 200f, worldHeight = 60f, zoom = 0.5f, topPadPx = 42f)
        assertEquals(142f, span.min, eps)
        assertEquals(172f, span.max, eps)
    }

    @Test fun verticalSpan_withNoPad_isPureScaling() {
        val span = PdfCursorFollow.verticalSpan(worldTop = 100f, worldHeight = 10f, zoom = 3f, topPadPx = 0f)
        assertEquals(300f, span.min, eps)
        assertEquals(330f, span.max, eps)
    }

    /** The horizontal axis has no leading pad at all — the column starts flush at x = 0. */
    @Test fun horizontalSpan_isPureScaling() {
        val span = PdfCursorFollow.horizontalSpan(worldLeft = 50f, worldWidth = 8f, zoom = 2f)
        assertEquals(100f, span.min, eps)
        assertEquals(116f, span.max, eps)
    }

    @Test fun horizontalSpan_atUnitZoom_isTheWorldSpan() {
        val span = PdfCursorFollow.horizontalSpan(worldLeft = 50f, worldWidth = 8f, zoom = 1f)
        assertEquals(50f, span.min, eps)
        assertEquals(58f, span.max, eps)
    }

    /** A zero-height cursor (a degenerate side-car rect) collapses to a point rather than inverting the span. */
    @Test fun verticalSpan_ofAZeroHeightRect_collapses() {
        val span = PdfCursorFollow.verticalSpan(worldTop = 200f, worldHeight = 0f, zoom = 2f, topPadPx = 42f)
        assertEquals(442f, span.min, eps)
        assertEquals(442f, span.max, eps)
    }
}
