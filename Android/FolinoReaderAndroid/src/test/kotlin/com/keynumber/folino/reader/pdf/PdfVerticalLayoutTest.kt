package com.keynumber.folino.reader.pdf

import com.keynumber.folino.reader.axisContentPx
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

    // -- unitContentHeightPx ----------------------------------------------------------------------

    @Test fun unitContentHeightSumsPagesAtScaleOnePlusTheGaps() {
        // Square pages against a 1000px viewport: each is 1000px tall at scale 1, and at rasterScale 1
        // the gap contributes its raw size.
        val unit = PdfVerticalLayout.unitContentHeightPx(
            viewportWidthPx = 1000,
            widthsPt = List(3) { 100.0 },
            heightsPt = List(3) { 100.0 },
            gapPx = 12f,
            rasterScale = 1f,
        )
        assertEquals(3 * 1000f + 2 * 12f, unit, 0.01f)
    }

    @Test fun unitContentHeightDividesTheGapByTheRasterScale() {
        // The gap is a fixed dp INSIDE the layer that scales by `scale / rasterScale`, so its scale-1
        // contribution is `gapPx / rasterScale` — see the KDoc.
        val unit = PdfVerticalLayout.unitContentHeightPx(
            viewportWidthPx = 1000,
            widthsPt = List(3) { 100.0 },
            heightsPt = List(3) { 100.0 },
            gapPx = 12f,
            rasterScale = 4f,
        )
        assertEquals(3 * 1000f + 2 * 3f, unit, 0.01f)
    }

    @Test fun unitContentHeightFollowsEachPagesOwnAspectRatio() {
        val unit = PdfVerticalLayout.unitContentHeightPx(
            viewportWidthPx = 1000,
            widthsPt = listOf(500.0, 1000.0),
            heightsPt = listOf(1000.0, 500.0),
            gapPx = 0f,
            rasterScale = 1f,
        )
        // Page 0 is twice as tall as it is wide (2000px), page 1 is half as tall as it is wide (500px).
        assertEquals(2500f, unit, 0.01f)
    }

    @Test fun unitContentHeightOfAnEmptyDocumentIsZero() {
        val unit = PdfVerticalLayout.unitContentHeightPx(1000, emptyList(), emptyList(), 12f, 1f)
        assertEquals(0f, unit, 0.01f)
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

    // -- Regression: the pannable extent vs. what is actually on screen ----------------------------
    // -- `PdfVerticalScore.kt` declares its content Box — and `ReaderViewportState` clamps every pan --
    // -- and pinch — with `axisContentPx(unitContentHeightPx(...), fixedPadY, scale)`. What is really --
    // -- ON SCREEN is the page `Column`: each page at the LIVE render width, separated by `liveGapPx`, --
    // -- inside the fixed top/bottom padding. Those two have to agree at every (scale, rasterScale)   --
    // -- pair, or a pinch would either strand content past the end of the pannable range or leave a   --
    // -- strip that cannot be reached. The on-screen side is summed inline here on purpose: it is the --
    // -- independent reference the geometry formula is being checked against.                         --
    // --
    // -- Both cases use a 3-page square-aspect document (100x100pt each, so only the aspect ratio
    // -- matters — not the absolute pt values), a 1000px viewport, gapPx=12f, topPadPx=bottomPadPx=16f.
    // -- (A JUnit test in this module cannot invoke the `@Composable` surface itself — no Compose UI
    // -- test runtime is set up here — so this is the closest achievable proxy.) `scale` is clamped to
    // -- `[MIN_READER_SCALE, MAX_READER_SCALE]` = `[1f, 8f]` by the shared viewport, so "zoomed out" is
    // -- only reachable as `scale < rasterScale` with BOTH >= 1 — the zoomed-out case below uses a
    // -- settle at `rasterScale=4f` pinched back to `scale=1.5f`, a state the real surface can be in.

    private val threeSquarePagesWidthsPt = List(3) { 100.0 }
    private val threeSquarePagesHeightsPt = List(3) { 100.0 }
    private val testGapPx = 12f
    private val testPadPx = 16f

    /** What the page `Column` actually occupies on screen at ([scale], [rasterScale]), padding included. */
    private fun onScreenContentHeightPx(scale: Float, rasterScale: Float): Float {
        val liveWidthPx = PdfVerticalLayout.renderWidthPx(1000, scale)
        val liveHeights =
            PdfVerticalLayout.pageHeightsPx(threeSquarePagesWidthsPt, threeSquarePagesHeightsPt, liveWidthPx)
        val liveGap = PdfVerticalLayout.liveGapPx(testGapPx, scale, rasterScale)
        return liveHeights.sum() + liveGap * (liveHeights.size - 1) + testPadPx * 2
    }

    /** The pannable extent the surface declares and the viewport clamps against at ([scale], [rasterScale]). */
    private fun pannableContentHeightPx(scale: Float, rasterScale: Float): Float = axisContentPx(
        unitContentPx = PdfVerticalLayout.unitContentHeightPx(
            viewportWidthPx = 1000,
            widthsPt = threeSquarePagesWidthsPt,
            heightsPt = threeSquarePagesHeightsPt,
            gapPx = testGapPx,
            rasterScale = rasterScale,
        ),
        fixedPadPx = testPadPx * 2,
        scale = scale,
    )

    @Test fun pannableExtentMatchesTheScreenAtRest() {
        assertEquals(onScreenContentHeightPx(1f, 1f), pannableContentHeightPx(1f, 1f), 0.5f)
        assertEquals(onScreenContentHeightPx(3f, 3f), pannableContentHeightPx(3f, 3f), 0.5f)
    }

    @Test fun pannableExtentMatchesTheScreenWhenZoomedInPastTheRasterSettle() {
        // 3 pages of 2000px, two live gaps of 24, 16+16 padding.
        assertEquals(6080f, onScreenContentHeightPx(scale = 2f, rasterScale = 1f), 0.5f)
        assertEquals(6080f, pannableContentHeightPx(scale = 2f, rasterScale = 1f), 0.5f)
    }

    @Test fun pannableExtentMatchesTheScreenWhenZoomedOutBelowTheRasterSettle() {
        // 3 pages of 1500px, two live gaps of 4.5, 16+16 padding.
        assertEquals(4541f, onScreenContentHeightPx(scale = 1.5f, rasterScale = 4f), 0.5f)
        assertEquals(4541f, pannableContentHeightPx(scale = 1.5f, rasterScale = 4f), 0.5f)
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

    // -- pageOriginsPx (PDF page-anchored annotation) -------------------------------------

    @Test fun pageOriginsAreColumnLocalWithNoTopPadding() {
        val heights = floatArrayOf(100f, 200f, 300f)
        val origins = PdfVerticalLayout.pageOriginsPx(heights, gapPx = 10f)
        assertArrayEquals(floatArrayOf(0f, 110f, 320f), origins, 0.01f)
    }

    @Test fun pageOriginsOfAnEmptyDocumentIsEmpty() {
        assertEquals(0, PdfVerticalLayout.pageOriginsPx(FloatArray(0), gapPx = 10f).size)
    }

    // -- pxPerPageMm (PDF pen/eraser were ~5x too thin) ------------------------

    @Test fun pxPerPageMmMatchesTheKnownA4PortraitRatio() {
        // A4 portrait is 595 x 842 pt ~= 209.9 x 297.2mm (595pt * 25.4/72). Rendered 1000px wide:
        // 1000 / 209.9028 ~= 4.7641 px/mm.
        val result = PdfVerticalLayout.pxPerPageMm(rasterWidthPx = 1000, pageWidthPt = 595.0)
        assertEquals(4.7641f, result, 0.001f)
    }

    @Test fun pxPerPageMmScalesWithRasterWidth() {
        val at1000 = PdfVerticalLayout.pxPerPageMm(rasterWidthPx = 1000, pageWidthPt = 595.0)
        val at2000 = PdfVerticalLayout.pxPerPageMm(rasterWidthPx = 2000, pageWidthPt = 595.0)
        assertEquals(at1000 * 2f, at2000, 0.001f)
    }

    @Test fun pxPerPageMmIsIdentityForANonPositivePageWidth() {
        assertEquals(1f, PdfVerticalLayout.pxPerPageMm(rasterWidthPx = 1000, pageWidthPt = 0.0), 0.0001f)
        assertEquals(1f, PdfVerticalLayout.pxPerPageMm(rasterWidthPx = 1000, pageWidthPt = -5.0), 0.0001f)
    }
}
