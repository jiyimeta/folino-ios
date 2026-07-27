package com.keynumber.folino.reader.pdf

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
}
