package com.keynumber.folino.reader.pdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A4 in PDF points (1/72 inch), the shape every MuseScore export lands on. */
private const val A4_WIDTH_PT = 595.0
private const val A4_HEIGHT_PT = 842.0

class PdfRasterBudgetTest {

    @Test fun ordinaryZoomIsNotTouched() {
        // 1080px viewport, raster scale 1: an A4 page is 1080 x ~1528, far inside the cap.
        assertEquals(1080, PdfRasterBudget.rasterWidthPx(1080, A4_WIDTH_PT, A4_HEIGHT_PT))
    }

    @Test fun aWidthWhoseHEIGHTWouldExceedTheCapIsReduced() {
        // The whole point of bounding the LARGER dimension: 4096 wide is itself legal, but a portrait
        // page that wide is 5794 tall, which is not.
        val capped = PdfRasterBudget.rasterWidthPx(4096, A4_WIDTH_PT, A4_HEIGHT_PT)
        assertTrue("expected a reduction, got $capped", capped < 4096)
        assertHeightWithinCap(capped, A4_WIDTH_PT, A4_HEIGHT_PT)
    }

    @Test fun theMaximumPinchOnATypicalPhoneIsBounded() {
        // The failure this cap exists for: 1080px viewport at the pinch ceiling of 8 asks for
        // 8640 x ~12227 (~420MB), the render OOMs, and the page draws blank white.
        val capped = PdfRasterBudget.rasterWidthPx(8640, A4_WIDTH_PT, A4_HEIGHT_PT)
        assertTrue("width $capped over the cap", capped <= PdfRasterBudget.MAX_RASTER_DIMENSION_PX)
        assertHeightWithinCap(capped, A4_WIDTH_PT, A4_HEIGHT_PT)
    }

    @Test fun aLandscapePageIsBoundedByItsWidthInstead() {
        // Larger dimension is the width here, so the cap lands on the requested width directly.
        assertEquals(
            PdfRasterBudget.MAX_RASTER_DIMENSION_PX,
            PdfRasterBudget.rasterWidthPx(8640, A4_HEIGHT_PT, A4_WIDTH_PT),
        )
    }

    @Test fun aSquarePageIsCappedOnBothDimensionsAtOnce() {
        assertEquals(PdfRasterBudget.MAX_RASTER_DIMENSION_PX, PdfRasterBudget.rasterWidthPx(9000, 500.0, 500.0))
    }

    @Test fun exactlyAtTheCapIsLeftAlone() {
        val requested = PdfRasterBudget.MAX_RASTER_DIMENSION_PX
        assertEquals(requested, PdfRasterBudget.rasterWidthPx(requested, 500.0, 500.0))
    }

    /** The `0` both surfaces use for "viewport not measured yet" must survive — callers gate on `<= 0`. */
    @Test fun theNotMeasuredSentinelPassesThrough() {
        assertEquals(0, PdfRasterBudget.rasterWidthPx(0, A4_WIDTH_PT, A4_HEIGHT_PT))
        assertEquals(-1, PdfRasterBudget.rasterWidthPx(-1, A4_WIDTH_PT, A4_HEIGHT_PT))
    }

    @Test fun aDegeneratePageSizeStillBoundsTheWidth() {
        assertEquals(PdfRasterBudget.MAX_RASTER_DIMENSION_PX, PdfRasterBudget.rasterWidthPx(8640, 0.0, 0.0))
        assertEquals(100, PdfRasterBudget.rasterWidthPx(100, 0.0, 842.0))
    }

    @Test fun theResultIsNeverZero() {
        // A pathologically tall page: even shrunk to fit, a bitmap request must stay renderable.
        assertTrue(PdfRasterBudget.rasterWidthPx(10, 1.0, 100_000.0) >= 1)
    }

    /**
     * Rounding must never push the constrained dimension back over the cap, which is why the
     * implementation floors. Sweeps a range of requests wide enough to hit both rounding directions.
     */
    @Test fun noRequestedWidthEverRoundsBackOverTheCap() {
        for (requested in 4000..9000 step 7) {
            val capped = PdfRasterBudget.rasterWidthPx(requested, A4_WIDTH_PT, A4_HEIGHT_PT)
            assertTrue(
                "width $capped over the cap for request $requested",
                capped <= PdfRasterBudget.MAX_RASTER_DIMENSION_PX,
            )
            assertHeightWithinCap(capped, A4_WIDTH_PT, A4_HEIGHT_PT)
        }
    }

    /**
     * Mirrors `PdfPageSource.renderAndCache`'s own height derivation (truncating, floored at 1) so the
     * assertion is about the bitmap that would actually be allocated, not an idealized one.
     */
    private fun assertHeightWithinCap(widthPx: Int, pageWidthPt: Double, pageHeightPt: Double) {
        val heightPx = (widthPx * pageHeightPt / pageWidthPt).toInt().coerceAtLeast(1)
        assertTrue(
            "height $heightPx (width $widthPx) over the cap",
            heightPx <= PdfRasterBudget.MAX_RASTER_DIMENSION_PX,
        )
    }
}
