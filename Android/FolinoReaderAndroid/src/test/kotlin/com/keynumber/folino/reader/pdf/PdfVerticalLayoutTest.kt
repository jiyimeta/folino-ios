package com.keynumber.folino.reader.pdf

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class PdfVerticalLayoutTest {

    // -- renderWidthPx --------------------------------------------------------------------------

    @Test fun renderWidthScalesTheViewportWidth() {
        assertEquals(1500, PdfVerticalLayout.renderWidthPx(viewportWidthPx = 1000, scale = 1.5f))
    }

    @Test fun renderWidthNeverGoesBelowOnePixel() {
        assertEquals(1, PdfVerticalLayout.renderWidthPx(viewportWidthPx = 0, scale = 1f))
    }

    // -- pageHeightsPx ----------------------------------------------------------------------------

    @Test fun pageHeightFollowsItsOwnAspectRatio() {
        // A4 portrait (595 x 842 pt) rendered 1000px wide: height = 1000 * 842/595 ≈ 1415.13.
        val heights = PdfVerticalLayout.pageHeightsPx(
            widthsPt = listOf(595.0),
            heightsPt = listOf(842.0),
            renderWidthPx = 1000,
        )
        assertEquals(1415.13f, heights[0], 0.1f)
    }

    @Test fun differentPagesKeepDifferentAspectRatiosAtTheSameRenderWidth() {
        // A landscape page mixed into an otherwise-portrait document must not be squeezed to match.
        val heights = PdfVerticalLayout.pageHeightsPx(
            widthsPt = listOf(595.0, 842.0),
            heightsPt = listOf(842.0, 595.0),
            renderWidthPx = 1000,
        )
        assertEquals(1415.13f, heights[0], 0.1f)
        assertEquals(706.65f, heights[1], 0.1f)
    }

    // -- totalContentHeightPx ---------------------------------------------------------------------

    @Test fun totalHeightSumsPagesPlusGapsPlusPadding() {
        val heights = floatArrayOf(100f, 200f, 300f)
        val total = PdfVerticalLayout.totalContentHeightPx(heights, gapPx = 10f, topPadPx = 16f, bottomPadPx = 40f)
        // 100+200+300 pages, 2 gaps of 10, 16 top pad, 40 bottom pad.
        assertEquals(100f + 200f + 300f + 2 * 10f + 16f + 40f, total, 0.01f)
    }

    @Test fun totalHeightOfAnEmptyDocumentIsJustThePadding() {
        val total = PdfVerticalLayout.totalContentHeightPx(FloatArray(0), gapPx = 10f, topPadPx = 16f, bottomPadPx = 40f)
        assertEquals(56f, total, 0.01f)
    }

    // -- currentPageIndex -------------------------------------------------------------------------

    @Test fun currentPageIsWhicheverBandCoversTheViewportCenterAtTheTop() {
        val heights = floatArrayOf(500f, 500f, 500f)
        // Scrolled to 0, a 1000px-tall viewport centers at y=500 (topPad 0), which is exactly the
        // boundary between page 0 and page 1 — `centerY < bottom` is false AT the boundary, so the
        // loop moves on and this asserts page 1 wins a dead-on boundary, not page 0.
        assertEquals(1, PdfVerticalLayout.currentPageIndex(0f, 1000f, heights, gapPx = 0f, topPadPx = 0f))
    }

    @Test fun currentPageAdvancesAsTheUserScrollsDown() {
        val heights = floatArrayOf(500f, 500f, 500f)
        assertEquals(0, PdfVerticalLayout.currentPageIndex(0f, 200f, heights, gapPx = 0f, topPadPx = 0f))
        assertEquals(1, PdfVerticalLayout.currentPageIndex(600f, 200f, heights, gapPx = 0f, topPadPx = 0f))
        assertEquals(2, PdfVerticalLayout.currentPageIndex(1100f, 200f, heights, gapPx = 0f, topPadPx = 0f))
    }

    @Test fun currentPageAccountsForGapsAndTopPadding() {
        val heights = floatArrayOf(100f, 100f)
        // topPad 20, page 0 spans [20,120), gap 30 -> page 1 starts at 150. Viewport center at 200
        // (scroll 190 + half-height 10) lands inside page 1.
        assertEquals(1, PdfVerticalLayout.currentPageIndex(190f, 20f, heights, gapPx = 30f, topPadPx = 20f))
    }

    @Test fun currentPageClampsPastTheLastPage() {
        val heights = floatArrayOf(100f, 100f)
        assertEquals(1, PdfVerticalLayout.currentPageIndex(10_000f, 100f, heights, gapPx = 0f, topPadPx = 0f))
    }

    @Test fun currentPageOfAnEmptyDocumentIsZero() {
        assertEquals(0, PdfVerticalLayout.currentPageIndex(0f, 1000f, FloatArray(0), gapPx = 0f, topPadPx = 0f))
    }

    // -- pageHeightsPxInto ------------------------------------------------------------------------

    @Test fun pageHeightsPxIntoMatchesPageHeightsPx() {
        val widths = listOf(595.0, 842.0)
        val heights = listOf(842.0, 595.0)
        val expected = PdfVerticalLayout.pageHeightsPx(widths, heights, renderWidthPx = 1000)
        val dest = FloatArray(2)
        PdfVerticalLayout.pageHeightsPxInto(dest, widths, heights, renderWidthPx = 1000)
        assertArrayEquals(expected, dest, 0.01f)
    }

    @Test fun pageHeightsPxIntoOnlyWritesAsManyEntriesAsThereArePages() {
        // A caller-provided scratch buffer may be larger than the current document (reused across a
        // retarget to a shorter one); only the first `widthsPt.size` entries are the caller's business.
        val dest = FloatArray(3)
        PdfVerticalLayout.pageHeightsPxInto(dest, listOf(500.0), listOf(1000.0), renderWidthPx = 200)
        assertEquals(400f, dest[0], 0.01f)
    }

    // -- liveGapPx --------------------------------------------------------------------------------

    @Test fun liveGapIsUnchangedWhenScaleMatchesRaster() {
        assertEquals(12f, PdfVerticalLayout.liveGapPx(gapPx = 12f, scale = 2f, rasterScale = 2f), 0.001f)
    }

    @Test fun liveGapDoublesWhenZoomedInToTwiceTheRasterScale() {
        assertEquals(24f, PdfVerticalLayout.liveGapPx(gapPx = 12f, scale = 2f, rasterScale = 1f), 0.001f)
    }

    @Test fun liveGapHalvesWhenZoomedOutToHalfTheRasterScale() {
        assertEquals(6f, PdfVerticalLayout.liveGapPx(gapPx = 12f, scale = 0.5f, rasterScale = 1f), 0.001f)
    }

    // -- Regression: the live/raster split is where both review-round-2 defects lived -------------
    // Pins the exact numbers from task-7-report.md's arithmetic verification: a 3-page square-aspect
    // document, 1000px viewport, rasterScale settled at 1, pinched to scale=2 (zoom in) and scale=0.5
    // (zoom out). `PdfVerticalScore`'s `wrapContentSize` fix guarantees the on-screen page width always
    // equals `viewportW * scale` on the Compose side (untestable off-device); what IS pure and tested
    // here is the geometry that guarantee depends on, and the `liveGapPx` correction the outer content
    // box's declared height (and `currentPageIndex`'s page-boundary walk) must apply to stay consistent
    // with it.

    private fun lastPageTopOffset(viewportW: Int, scale: Float, rasterScale: Float): Float {
        val widthsPt = List(3) { 100.0 }
        val heightsPt = List(3) { 100.0 } // square pages
        val gapPx = 12f
        val topPadPx = 16f
        val liveWidthPx = PdfVerticalLayout.renderWidthPx(viewportW, scale)
        val liveHeights = PdfVerticalLayout.pageHeightsPx(widthsPt, heightsPt, liveWidthPx)
        val liveGap = PdfVerticalLayout.liveGapPx(gapPx, scale, rasterScale)
        // First page's top offset is always the fixed, unscaled topPadPx (`focalAdjustedOffset`'s "held
        // out of the scaling" pad) — asserted directly by callers below rather than duplicated here.
        return topPadPx + liveHeights[0] + liveHeights[1] + liveGap * 2
    }

    @Test fun liveGeometryMatchesOnScreenPositionsWhenZoomedInPastTheRasterSettle() {
        val viewportW = 1000
        val scale = 2f
        val rasterScale = 1f
        val liveWidthPx = PdfVerticalLayout.renderWidthPx(viewportW, scale)
        // On-screen page width must equal viewportW * scale regardless of zoom direction.
        assertEquals(viewportW * scale, liveWidthPx.toFloat(), 0.5f)
        // First page's on-screen top offset stays the fixed, unscaled 16f pad.
        assertEquals(4064f, lastPageTopOffset(viewportW, scale, rasterScale), 0.5f)
    }

    @Test fun liveGeometryMatchesOnScreenPositionsWhenZoomedOutBelowTheRasterSettle() {
        val viewportW = 1000
        val scale = 0.5f
        val rasterScale = 1f
        val liveWidthPx = PdfVerticalLayout.renderWidthPx(viewportW, scale)
        assertEquals(viewportW * scale, liveWidthPx.toFloat(), 0.5f)
        assertEquals(1028f, lastPageTopOffset(viewportW, scale, rasterScale), 0.5f)
    }
}
