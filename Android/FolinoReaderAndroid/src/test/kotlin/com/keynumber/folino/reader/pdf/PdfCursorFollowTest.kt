package com.keynumber.folino.reader.pdf

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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

    // The tap direction: viewport px → world px, the inverse of the camera the cursor Canvas draws through. The pad
    // asymmetry above is what makes this worth pinning separately from the follow spans — a tap must land on the same
    // world point the cursor would be drawn at, or seeking lands a system off at high zoom.

    @Test fun worldPointForTap_atRest_onlyRemovesThePad() {
        val world = PdfCursorFollow.worldPointForTap(
            tap = Offset(120f, 242f), hScrollPx = 0f, vScrollPx = 0f, zoom = 1f, topPadPx = 42f,
        )!!
        assertEquals(120f, world.x, eps)
        assertEquals(200f, world.y, eps)
    }

    @Test fun worldPointForTap_addsTheScrollOffsetsBeforeDividing() {
        val world = PdfCursorFollow.worldPointForTap(
            tap = Offset(10f, 10f), hScrollPx = 90f, vScrollPx = 432f, zoom = 2f, topPadPx = 42f,
        )!!
        assertEquals(50f, world.x, eps)
        assertEquals(200f, world.y, eps)
    }

    /** The round trip that actually matters: the tap inverse undoes [verticalSpan]/[horizontalSpan]'s forward map. */
    @Test fun worldPointForTap_roundTripsTheDrawnSpans() {
        val zoom = 1.75f
        val pad = 42f
        val hScroll = 33f
        val vScroll = 517f
        val vSpan = PdfCursorFollow.verticalSpan(worldTop = 320f, worldHeight = 40f, zoom = zoom, topPadPx = pad)
        val hSpan = PdfCursorFollow.horizontalSpan(worldLeft = 88f, worldWidth = 6f, zoom = zoom)
        // Where that cursor's top-left actually sits on screen: scroll-space minus the current scroll offsets.
        val world = PdfCursorFollow.worldPointForTap(
            tap = Offset(hSpan.min - hScroll, vSpan.min - vScroll),
            hScrollPx = hScroll,
            vScrollPx = vScroll,
            zoom = zoom,
            topPadPx = pad,
        )!!
        assertEquals(88f, world.x, 1e-3f)
        assertEquals(320f, world.y, 1e-3f)
    }

    @Test fun worldPointForTap_refusesANonPositiveZoom() {
        assertNull(
            PdfCursorFollow.worldPointForTap(
                tap = Offset(10f, 10f), hScrollPx = 0f, vScrollPx = 0f, zoom = 0f, topPadPx = 0f,
            ),
        )
    }
}
