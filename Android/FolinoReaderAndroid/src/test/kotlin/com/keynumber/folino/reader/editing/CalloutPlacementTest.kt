package com.keynumber.folino.reader.editing

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.IntSize
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards against the class of bug review caught in Task 8's fix round 1: the first cut of
 * [resolveCalloutPlacement] (then inline in [EditingCallout]'s own `Modifier.offset` block) clamped Y across a
 * SHARED top/bottom range regardless of which side the card was parked on, so a note near the top of the
 * viewport got its card's fixed-above position pinned back down onto the note itself — the callout covering the
 * exact thing it describes.
 *
 * These tests assert the OUTCOME that matters — the card's resulting rect does not overlap the selection rect —
 * not just that the function returns whatever numbers it happens to compute, which is why each test rebuilds
 * both rects from the returned [CalloutPlacement] and checks them geometrically.
 */
class CalloutPlacementTest {
    // A representative selection and card size, reused by the cases that don't need to vary them: a caret-shaped
    // note rect (narrow, one staff band tall) and a card noticeably bigger than the gap, so a placement bug shows
    // up as real, non-trivial overlap rather than a hairline.
    private val selWidthPx = 20f
    private val selHeightPx = 60f
    private val cardWidthPx = 160f
    private val cardHeightPx = 80f
    private val gapPx = 12f
    private val edgeInsetPx = 8f
    private val viewportSizePx = IntSize(400, 800)

    @Test
    fun `an ordinary mid-viewport selection sits above with the intended gap`() {
        val selLeftPx = 120f
        val selTopPx = 300f

        val placement = resolveCalloutPlacement(
            selLeftPx = selLeftPx,
            selTopPx = selTopPx,
            selWidthPx = selWidthPx,
            selHeightPx = selHeightPx,
            cardWidthPx = cardWidthPx,
            cardHeightPx = cardHeightPx,
            gapPx = gapPx,
            edgeInsetPx = edgeInsetPx,
            viewportPanPx = Offset.Zero,
            viewportSizePx = viewportSizePx,
        )

        assertEquals(CalloutSide.ABOVE, placement.side)
        // The card's bottom edge sits exactly gapPx above the selection's top edge — not merely "above it
        // somewhere".
        assertEquals(selTopPx - gapPx, (placement.offset.y + cardHeightPx), 0.01f)
        assertNoOverlap(placement, selLeftPx, selTopPx, cardWidthPx, cardHeightPx)
    }

    @Test
    fun `a selection near the top resolves below, not overlapping`() {
        val selLeftPx = 120f
        val selTopPx = 20f // less than gapPx + cardHeightPx above the viewport's own top edge

        val placement = resolveCalloutPlacement(
            selLeftPx = selLeftPx,
            selTopPx = selTopPx,
            selWidthPx = selWidthPx,
            selHeightPx = selHeightPx,
            cardWidthPx = cardWidthPx,
            cardHeightPx = cardHeightPx,
            gapPx = gapPx,
            edgeInsetPx = edgeInsetPx,
            viewportPanPx = Offset.Zero,
            viewportSizePx = viewportSizePx,
        )

        assertEquals(CalloutSide.BELOW, placement.side)
        assertNoOverlap(placement, selLeftPx, selTopPx, cardWidthPx, cardHeightPx)
    }

    @Test
    fun `a selection near the bottom still resolves above`() {
        val selLeftPx = 120f
        val selTopPx = 760f // near the bottom of an 800px-tall viewport — plenty of room above, none below

        val placement = resolveCalloutPlacement(
            selLeftPx = selLeftPx,
            selTopPx = selTopPx,
            selWidthPx = selWidthPx,
            selHeightPx = selHeightPx,
            cardWidthPx = cardWidthPx,
            cardHeightPx = cardHeightPx,
            gapPx = gapPx,
            edgeInsetPx = edgeInsetPx,
            viewportPanPx = Offset.Zero,
            viewportSizePx = viewportSizePx,
        )

        assertEquals(CalloutSide.ABOVE, placement.side)
        assertNoOverlap(placement, selLeftPx, selTopPx, cardWidthPx, cardHeightPx)
    }

    @Test
    fun `a selection near the left edge clamps horizontally without leaving the viewport`() {
        val selLeftPx = 2f // the card, centered on this, would otherwise want to start left of the viewport
        val selTopPx = 300f

        val placement = resolveCalloutPlacement(
            selLeftPx = selLeftPx,
            selTopPx = selTopPx,
            selWidthPx = selWidthPx,
            selHeightPx = selHeightPx,
            cardWidthPx = cardWidthPx,
            cardHeightPx = cardHeightPx,
            gapPx = gapPx,
            edgeInsetPx = edgeInsetPx,
            viewportPanPx = Offset.Zero,
            viewportSizePx = viewportSizePx,
        )

        assertEquals(edgeInsetPx, placement.offset.x.toFloat(), 0.5f)
        assertTrue("card left edge must not leave the viewport", placement.offset.x >= 0)
        assertNoOverlap(placement, selLeftPx, selTopPx, cardWidthPx, cardHeightPx)
    }

    @Test
    fun `a selection near the right edge clamps horizontally without leaving the viewport`() {
        val selLeftPx = viewportSizePx.width - selWidthPx - 2f // hugging the right edge
        val selTopPx = 300f

        val placement = resolveCalloutPlacement(
            selLeftPx = selLeftPx,
            selTopPx = selTopPx,
            selWidthPx = selWidthPx,
            selHeightPx = selHeightPx,
            cardWidthPx = cardWidthPx,
            cardHeightPx = cardHeightPx,
            gapPx = gapPx,
            edgeInsetPx = edgeInsetPx,
            viewportPanPx = Offset.Zero,
            viewportSizePx = viewportSizePx,
        )

        val expectedMaxX = viewportSizePx.width - cardWidthPx - edgeInsetPx
        assertEquals(expectedMaxX, placement.offset.x.toFloat(), 0.5f)
        assertTrue(
            "card right edge must not leave the viewport",
            placement.offset.x + cardWidthPx <= viewportSizePx.width,
        )
        assertNoOverlap(placement, selLeftPx, selTopPx, cardWidthPx, cardHeightPx)
    }

    @Test
    fun `a panned viewport clamps against the CURRENT scroll window, not the origin`() {
        // The same near-top selection as the BELOW test, but the viewport has scrolled down 500px — so this
        // selection's document-space Y (520) is nowhere near y=0, only near the CURRENTLY VISIBLE top edge.
        val viewportPanPx = Offset(0f, 500f)
        val selLeftPx = 120f
        val selTopPx = 520f

        val placement = resolveCalloutPlacement(
            selLeftPx = selLeftPx,
            selTopPx = selTopPx,
            selWidthPx = selWidthPx,
            selHeightPx = selHeightPx,
            cardWidthPx = cardWidthPx,
            cardHeightPx = cardHeightPx,
            gapPx = gapPx,
            edgeInsetPx = edgeInsetPx,
            viewportPanPx = viewportPanPx,
            viewportSizePx = viewportSizePx,
        )

        assertEquals(CalloutSide.BELOW, placement.side)
        assertNoOverlap(placement, selLeftPx, selTopPx, cardWidthPx, cardHeightPx)
    }

    /** Fails with the two rects' coordinates if the card's placed rect and the selection's own rect intersect —
     * the geometric property that actually matters, independent of which numbers [resolveCalloutPlacement] used
     * to get there. */
    private fun assertNoOverlap(
        placement: CalloutPlacement,
        selLeftPx: Float,
        selTopPx: Float,
        cardWidthPx: Float,
        cardHeightPx: Float,
    ) {
        val cardLeft = placement.offset.x.toFloat()
        val cardTop = placement.offset.y.toFloat()
        val cardRight = cardLeft + cardWidthPx
        val cardBottom = cardTop + cardHeightPx
        val selRight = selLeftPx + selWidthPx
        val selBottom = selTopPx + selHeightPx

        val overlaps = cardLeft < selRight && cardRight > selLeftPx && cardTop < selBottom && cardBottom > selTopPx
        assertTrue(
            "card rect [$cardLeft,$cardTop,$cardRight,$cardBottom] overlaps selection rect " +
                "[$selLeftPx,$selTopPx,$selRight,$selBottom]",
            !overlaps,
        )
    }
}
