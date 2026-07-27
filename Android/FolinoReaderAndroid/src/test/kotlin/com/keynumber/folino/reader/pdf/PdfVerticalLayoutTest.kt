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

    @Test fun pageHeightsPxIntoWritesExactlyOneEntryPerPage() {
        // The contract is strict — `dest` must be sized EXACTLY `widthsPt.size` (see the KDoc: a larger
        // buffer would leave stale trailing entries `currentPageIndex` would read as phantom pages). This
        // just confirms a correctly-sized `dest` gets every entry written, matching `pageHeightsPx`.
        val dest = FloatArray(1)
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

    // -- Regression: `totalContentHeightPx`/`currentPageIndex`, fed the SAME `liveGapPx`-corrected gap --
    // -- `PdfVerticalScore.kt` feeds them, on a 3-page square-aspect document (100x100pt each, so aspect --
    // -- ratio is the only thing that matters — not the absolute pt values), 1000px viewport, gapPx=12f, --
    // -- topPadPx=bottomPadPx=16f. Unlike the private-helper version these replace, every assertion here --
    // -- calls the REAL `PdfVerticalLayout` functions `PdfVerticalScore.kt` calls — not a second,
    // -- independent re-derivation of the same formula — so a bug in either function's own arithmetic
    // -- would be caught here. (A JUnit test in this module cannot invoke the `@Composable` surface
    // -- itself — no Compose UI test runtime is set up here — so this is the closest achievable proxy;
    // -- see task-7-report.md's round-3 fix notes for the honest limit of what this does and doesn't
    // -- cover.) `scale` is clamped to `[1f, 8f]` in the real pinch gesture (`PdfVerticalScore.kt`'s
    // -- `coerceIn(1f, 8f)`), so "zoomed out" is only reachable as `scale < rasterScale` with BOTH >= 1 —
    // -- the zoomed-out case below uses a settle at `rasterScale=4f` pinched back to `scale=1.5f`, a state
    // -- the real surface can actually be in (not the `scale=0.5f` used in the prior round, which the
    // -- clamp makes unreachable regardless of `rasterScale`).

    private val threeSquarePagesWidthsPt = List(3) { 100.0 }
    private val threeSquarePagesHeightsPt = List(3) { 100.0 }
    private val testGapPx = 12f
    private val testPadPx = 16f

    @Test fun contentHeightUsesTheLiveGapWhenZoomedInPastTheRasterSettle() {
        val scale = 2f
        val rasterScale = 1f
        val liveWidthPx = PdfVerticalLayout.renderWidthPx(1000, scale)
        val liveHeights =
            PdfVerticalLayout.pageHeightsPx(threeSquarePagesWidthsPt, threeSquarePagesHeightsPt, liveWidthPx)
        val liveGap = PdfVerticalLayout.liveGapPx(testGapPx, scale, rasterScale)

        val contentHeightPx = PdfVerticalLayout.totalContentHeightPx(liveHeights, liveGap, testPadPx, testPadPx)
        assertEquals(6080f, contentHeightPx, 0.5f)
    }

    @Test fun contentHeightUsesTheLiveGapWhenZoomedOutBelowTheRasterSettle() {
        val scale = 1.5f
        val rasterScale = 4f
        val liveWidthPx = PdfVerticalLayout.renderWidthPx(1000, scale)
        val liveHeights =
            PdfVerticalLayout.pageHeightsPx(threeSquarePagesWidthsPt, threeSquarePagesHeightsPt, liveWidthPx)
        val liveGap = PdfVerticalLayout.liveGapPx(testGapPx, scale, rasterScale)

        val contentHeightPx = PdfVerticalLayout.totalContentHeightPx(liveHeights, liveGap, testPadPx, testPadPx)
        assertEquals(4541f, contentHeightPx, 0.5f)
    }

    @Test fun currentPageBoundaryShiftsWithTheLiveGapWhenZoomedInPastTheRasterSettle() {
        val scale = 2f
        val rasterScale = 1f
        val liveWidthPx = PdfVerticalLayout.renderWidthPx(1000, scale)
        val liveHeights =
            PdfVerticalLayout.pageHeightsPx(threeSquarePagesWidthsPt, threeSquarePagesHeightsPt, liveWidthPx)
        val liveGap = PdfVerticalLayout.liveGapPx(testGapPx, scale, rasterScale)

        // Page 1 (NOT the last page, so its bound check is genuinely gap-sensitive — the last page always
        // wins past its own start regardless of gap, per `currentPageIndex`'s `i == lastIndex` clause)
        // spans y=[2040, 4040) using the correct, SCALED gap (24). y=4035 lands just inside it. With the
        // raw, unscaled gap (12) that band would instead be y=[2028, 4028), which does NOT contain 4035 —
        // so this assertion would flip to `2` if `liveGap` here were replaced by the raw `testGapPx`.
        val page = PdfVerticalLayout.currentPageIndex(
            scrollPx = 4035f,
            viewportHeightPx = 0f,
            pageHeightsPx = liveHeights,
            gapPx = liveGap,
            topPadPx = testPadPx,
        )
        assertEquals(1, page)
    }

    @Test fun currentPageBoundaryShiftsWithTheLiveGapWhenZoomedOutBelowTheRasterSettle() {
        val scale = 1.5f
        val rasterScale = 4f
        val liveWidthPx = PdfVerticalLayout.renderWidthPx(1000, scale)
        val liveHeights =
            PdfVerticalLayout.pageHeightsPx(threeSquarePagesWidthsPt, threeSquarePagesHeightsPt, liveWidthPx)
        val liveGap = PdfVerticalLayout.liveGapPx(testGapPx, scale, rasterScale)

        // Page 1 spans y=[1520.5, 3020.5) using the correct, SCALED gap (4.5). y=3024 lands just PAST it,
        // in page 2. With the raw, unscaled gap (12) that band would instead be y=[1528, 3028), which DOES
        // contain 3024 — so this assertion would flip to `1` if `liveGap` here were replaced by the raw
        // `testGapPx`.
        val page = PdfVerticalLayout.currentPageIndex(
            scrollPx = 3024f,
            viewportHeightPx = 0f,
            pageHeightsPx = liveHeights,
            gapPx = liveGap,
            topPadPx = testPadPx,
        )
        assertEquals(2, page)
    }

    // -- pageOriginsPx / pageIndexForY (Task 11: PDF page-anchored annotation) --------------------

    @Test fun pageOriginsAreColumnLocalWithNoTopPadding() {
        val heights = floatArrayOf(100f, 200f, 300f)
        val origins = PdfVerticalLayout.pageOriginsPx(heights, gapPx = 10f)
        assertArrayEquals(floatArrayOf(0f, 110f, 320f), origins, 0.01f)
    }

    @Test fun pageOriginsOfAnEmptyDocumentIsEmpty() {
        assertEquals(0, PdfVerticalLayout.pageOriginsPx(FloatArray(0), gapPx = 10f).size)
    }

    @Test fun pageIndexForYInsideABandReturnsThatPage() {
        val heights = floatArrayOf(100f, 100f, 100f)
        // Bands (gap 10): [0,100) [110,210) [220,320).
        assertEquals(0, PdfVerticalLayout.pageIndexForY(50f, heights, gapPx = 10f))
        assertEquals(1, PdfVerticalLayout.pageIndexForY(150f, heights, gapPx = 10f))
        assertEquals(2, PdfVerticalLayout.pageIndexForY(300f, heights, gapPx = 10f))
    }

    @Test fun pageIndexForYInTheGapResolvesToTheNearerPage() {
        val heights = floatArrayOf(100f, 100f)
        // Band 0: [0,100), band 1: [110,210) — gap is (100,110).
        assertEquals(0, PdfVerticalLayout.pageIndexForY(102f, heights, gapPx = 10f))
        assertEquals(1, PdfVerticalLayout.pageIndexForY(108f, heights, gapPx = 10f))
    }

    @Test fun pageIndexForYAtTheExactGapMidpointTiesToTheEarlierPage() {
        val heights = floatArrayOf(100f, 100f)
        // Gap midpoint is 105 — equidistant from both bands; `<` (not `<=`) keeps the first minimum found.
        assertEquals(0, PdfVerticalLayout.pageIndexForY(105f, heights, gapPx = 10f))
    }

    @Test fun pageIndexForYPastTheLastPageClampsToIt() {
        val heights = floatArrayOf(100f, 100f)
        assertEquals(1, PdfVerticalLayout.pageIndexForY(10_000f, heights, gapPx = 10f))
    }

    @Test fun pageIndexForYBeforeTheFirstPageClampsToIt() {
        val heights = floatArrayOf(100f, 100f)
        assertEquals(0, PdfVerticalLayout.pageIndexForY(-50f, heights, gapPx = 10f))
    }

    @Test fun pageIndexForYOfAnEmptyDocumentIsZero() {
        assertEquals(0, PdfVerticalLayout.pageIndexForY(0f, FloatArray(0), gapPx = 10f))
    }
}
