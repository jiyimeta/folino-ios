package com.keynumber.folino.reader.editing

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.IntSize
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards against two related bugs, both caught in review across Task 8's two fix rounds.
 *
 * **Fix round 1:** the first cut of [resolveCalloutPlacement] (then inline in [EditingCallout]'s own
 * `Modifier.offset` block) clamped Y across a SHARED top/bottom range regardless of which side the card was
 * parked on, so a note near the top of the viewport got its card's fixed-above position pinned back down onto
 * the note itself — the callout covering the exact thing it describes. Fixed by deciding the side from the
 * UNCLAMPED positions only.
 *
 * **Fix round 2:** the round-1 fix over-corrected by removing the Y clamp entirely, so a viewport too short to
 * fit the card on EITHER side let the card render off-screen rather than merely overlapping — the opposite of
 * iOS's own `position(for:in:side:)`, which clamps unconditionally once a side is picked, accepting overlap as
 * the lesser evil to staying fully off-screen. Fixed by restoring an unconditional last-resort clamp AFTER the
 * side decision, which the last test below exercises directly.
 *
 * Most of these tests assert the OUTCOME that matters — the card's resulting rect does not overlap the
 * selection rect — not just that the function returns whatever numbers it happens to compute, which is why
 * each test rebuilds both rects from the returned [CalloutPlacement] and checks them geometrically. The last
 * test asserts the opposite (deliberate overlap, full containment) for the one case where that is correct.
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

    /**
     * DELIBERATE overlap: a viewport short enough (100px) that the card (80px tall) does not fit on EITHER
     * side without clipping past an edge — above would run off the top, below would run off the bottom — but
     * still tall enough that the card itself CAN fit somewhere inside it. This is the degenerate case fix round
     * 2 restores: iOS's `position(for:in:side:)` clamps `rawY` into the viewport unconditionally, even when the
     * chosen side's own unclamped position doesn't fit, on the stated rationale that a card the reader cannot
     * see at all is worse than one sitting over its note. The overlap asserted below is that trade, not a
     * regression of the top-of-viewport fix (finding 1 of fix round 1) — see that fix's own tests above, none
     * of which exercise a viewport this short.
     */
    @Test
    fun `a viewport too short for the card on either side clamps fully on-screen and is allowed to overlap`() {
        val shortViewportPx = IntSize(400, 100)
        val selLeftPx = 190f
        val selTopPx = 45f
        val selHeightPxHere = 10f

        val placement = resolveCalloutPlacement(
            selLeftPx = selLeftPx,
            selTopPx = selTopPx,
            selWidthPx = selWidthPx,
            selHeightPx = selHeightPxHere,
            cardWidthPx = cardWidthPx,
            cardHeightPx = cardHeightPx,
            gapPx = gapPx,
            edgeInsetPx = edgeInsetPx,
            viewportPanPx = Offset.Zero,
            viewportSizePx = shortViewportPx,
        )

        // Neither side's unclamped position fits: above would start at 45 - 12 - 80 = -47 (off the top);
        // below would end at 45 + 10 + 12 + 80 = 147 (off the bottom of a 100px-tall viewport). The side
        // decision still runs first and picks BELOW (the closer miss), then the clamp pulls it fully on-screen.
        assertEquals(CalloutSide.BELOW, placement.side)

        val cardLeft = placement.offset.x.toFloat()
        val cardTop = placement.offset.y.toFloat()
        val cardRight = cardLeft + cardWidthPx
        val cardBottom = cardTop + cardHeightPx
        assertTrue(
            "card left [$cardLeft] must not be left of the viewport's own edge inset",
            cardLeft >= edgeInsetPx - 0.5f,
        )
        assertTrue(
            "card right [$cardRight] must not run past the viewport's right edge inset",
            cardRight <= shortViewportPx.width - edgeInsetPx + 0.5f,
        )
        assertTrue(
            "card top [$cardTop] must not be above the viewport's own top edge inset",
            cardTop >= edgeInsetPx - 0.5f,
        )
        assertTrue(
            "card bottom [$cardBottom] must not run past the viewport's bottom edge inset",
            cardBottom <= shortViewportPx.height - edgeInsetPx + 0.5f,
        )

        // The point of this test: containment was bought by tolerating overlap, not by magically finding room
        // that doesn't exist. Asserting the OPPOSITE of assertNoOverlap's condition makes that trade explicit
        // rather than leaving it as an unstated side effect a future reader might "fix" back into finding 1.
        val selRight = selLeftPx + selWidthPx
        val selBottom = selTopPx + selHeightPxHere
        val overlapsSelection =
            cardLeft < selRight && cardRight > selLeftPx && cardTop < selBottom && cardBottom > selTopPx
        assertTrue(
            "expected the degenerate case to overlap the selection (containment over non-overlap) — if this " +
                "is false, either the scenario no longer reproduces the degenerate case or a later change " +
                "regressed the clamp",
            overlapsSelection,
        )
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
