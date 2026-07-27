package com.keynumber.folino.reader.pdf

import org.junit.Assert.assertEquals
import org.junit.Test

class PagedPdfLayoutTest {

    // -- fitWidthPx -------------------------------------------------------------------------------

    @Test fun fitWidthIsWidthConstrainedWhenTheViewportIsNarrowerThanThePage() {
        // A4 portrait (595 x 842 pt) in a 1000 x 2000 viewport: widthRatio = 1000/595 ≈ 1.68,
        // heightRatio = 2000/842 ≈ 2.38 — width is the tighter fit, so the page's own width maps exactly
        // onto the viewport's width.
        val fitWidth = PagedPdfLayout.fitWidthPx(
            viewportWidthPx = 1000,
            viewportHeightPx = 2000,
            pageWidthPt = 595.0,
            pageHeightPt = 842.0,
        )
        assertEquals(1000, fitWidth)
    }

    @Test fun fitWidthIsHeightConstrainedWhenTheViewportIsShorterThanThePage() {
        // Same A4 portrait page in a 2000 x 1000 (wide, short) viewport: widthRatio = 2000/595 ≈ 3.36,
        // heightRatio = 1000/842 ≈ 1.19 — height is the tighter fit, so the page is letterboxed on width.
        val fitWidth = PagedPdfLayout.fitWidthPx(
            viewportWidthPx = 2000,
            viewportHeightPx = 1000,
            pageWidthPt = 595.0,
            pageHeightPt = 842.0,
        )
        assertEquals(707, fitWidth)
    }

    @Test fun fitWidthIsZeroForAnUnmeasuredViewport() {
        assertEquals(0, PagedPdfLayout.fitWidthPx(0, 0, 595.0, 842.0))
        assertEquals(0, PagedPdfLayout.fitWidthPx(1000, 0, 595.0, 842.0))
    }

    @Test fun fitWidthIsZeroForADegeneratePageSize() {
        assertEquals(0, PagedPdfLayout.fitWidthPx(1000, 2000, 0.0, 842.0))
        assertEquals(0, PagedPdfLayout.fitWidthPx(1000, 2000, 595.0, 0.0))
    }

    // -- renderWidthPx ------------------------------------------------------------------------------

    @Test fun renderWidthScalesTheFitWidth() {
        assertEquals(1500, PagedPdfLayout.renderWidthPx(fitWidthPx = 1000, scale = 1.5f))
    }

    @Test fun renderWidthNeverGoesBelowOnePixel() {
        assertEquals(1, PagedPdfLayout.renderWidthPx(fitWidthPx = 0, scale = 1f))
    }

    // -- heightForWidthPx ---------------------------------------------------------------------------

    @Test fun heightFollowsThePagesOwnAspectRatio() {
        // A4 portrait (595 x 842 pt) rendered 1000px wide: height = 1000 * 842/595 ≈ 1415.13 -> 1415.
        val height = PagedPdfLayout.heightForWidthPx(renderWidthPx = 1000, pageWidthPt = 595.0, pageHeightPt = 842.0)
        assertEquals(1415, height)
    }

    // -- panBoundPx -----------------------------------------------------------------------------------

    @Test fun panBoundIsZeroWhenTheContentFitsInsideTheViewport() {
        assertEquals(0f, PagedPdfLayout.panBoundPx(contentSizePx = 800f, viewportSizePx = 1000f), 0.001f)
        assertEquals(0f, PagedPdfLayout.panBoundPx(contentSizePx = 1000f, viewportSizePx = 1000f), 0.001f)
    }

    @Test fun panBoundIsHalfTheExcessWhenTheContentOverflowsTheViewport() {
        assertEquals(250f, PagedPdfLayout.panBoundPx(contentSizePx = 1500f, viewportSizePx = 1000f), 0.001f)
    }

    // -- focalAdjustedPan -----------------------------------------------------------------------------

    @Test fun focalAdjustedPanKeepsAnOffCenterTouchPointFixedAcrossAZoomStep() {
        // Hand-derived from the affine mapping the class doc describes: with no prior pan, a 1000px
        // viewport, and a touch at x=800 (300px right of center), doubling the zoom (ratio=2) must shift
        // the pan by -300 to hold that same touch point fixed on screen.
        assertEquals(
            -300f,
            PagedPdfLayout.focalAdjustedPan(panBefore = 0f, centroidPx = 800f, viewportSizePx = 1000f, ratio = 2f),
            0.001f,
        )
    }

    // -- clampPan -------------------------------------------------------------------------------------
    // This is the exact math `PagedPdfScore`'s pinch/pan gesture applies every frame, and it is where the
    // CENTERED-content assumption baked into `panBoundPx` actually gets exercised end to end (`renderWidthPx`
    // -> `heightForWidthPx` -> `panBoundPx`, per axis) — see `clampPan`'s own KDoc for why this, not
    // `panBoundPx` alone, is the function most likely to catch a regression back to top-left-anchored content.

    @Test fun clampPanZeroesBothAxesWhenTheContentFitsExactlyInsideTheViewport() {
        // A 1000x1000 page rendered at its fit width (1000) exactly fills a 1000x1000 viewport on both
        // axes, so neither axis has any room to pan — any requested offset clamps to zero.
        val (x, y) = PagedPdfLayout.clampPan(
            panXPx = 500f,
            panYPx = -500f,
            atScale = 1f,
            fitWidthPx = 1000,
            pageWidthPt = 100.0,
            pageHeightPt = 100.0,
            viewportWidthPx = 1000f,
            viewportHeightPx = 1000f,
        )
        assertEquals(0f, x, 0.001f)
        assertEquals(0f, y, 0.001f)
    }

    @Test fun clampPanAllowsUpToTheLiveBoundWhenZoomedIn() {
        // Same page zoomed to atScale=2 renders 2000x2000 inside the 1000x1000 viewport — half the excess
        // (500) is the bound on each axis — and a requested offset beyond that clamps down to it.
        val (x, y) = PagedPdfLayout.clampPan(
            panXPx = 800f,
            panYPx = -800f,
            atScale = 2f,
            fitWidthPx = 1000,
            pageWidthPt = 100.0,
            pageHeightPt = 100.0,
            viewportWidthPx = 1000f,
            viewportHeightPx = 1000f,
        )
        assertEquals(500f, x, 0.001f)
        assertEquals(-500f, y, 0.001f)
    }

    @Test fun clampPanLeavesAnInBoundsOffsetUnchanged() {
        val (x, y) = PagedPdfLayout.clampPan(
            panXPx = 100f,
            panYPx = -100f,
            atScale = 2f,
            fitWidthPx = 1000,
            pageWidthPt = 100.0,
            pageHeightPt = 100.0,
            viewportWidthPx = 1000f,
            viewportHeightPx = 1000f,
        )
        assertEquals(100f, x, 0.001f)
        assertEquals(-100f, y, 0.001f)
    }

    @Test fun clampPanBoundsEachAxisIndependentlyForALetterboxedPage() {
        // A portrait page (100 x 200 pt) fit-rendered 500px wide is 1000px tall. In a 1000 (w) x 800 (h)
        // viewport, width fits exactly (bound 0) while height overflows by 200 (bound 100) — the two axes
        // must clamp independently, not share one bound.
        val (x, y) = PagedPdfLayout.clampPan(
            panXPx = 50f,
            panYPx = 250f,
            atScale = 1f,
            fitWidthPx = 500,
            pageWidthPt = 100.0,
            pageHeightPt = 200.0,
            viewportWidthPx = 1000f,
            viewportHeightPx = 800f,
        )
        assertEquals(0f, x, 0.001f)
        assertEquals(100f, y, 0.001f)
    }

    // -- annotationCameraTranslate (Task 11: PDF page-anchored annotation) -------------------------

    @Test fun annotationCameraIsIdentityAtRestWithNoPan() {
        // Raster content already matches the viewport 1:1, zoom 1x, no pan — the raster page's own
        // top-left (0, 0) must map straight to the viewport's top-left (0, 0), matching where the
        // bitmap's own `graphicsLayer` (transformOrigin 0.5/0.5, scale 1, translate 0) paints it.
        val (tx, ty) = PagedPdfLayout.annotationCameraTranslate(
            zoom = 1f,
            rasterWidthPx = 1000,
            rasterHeightPx = 2000,
            viewportWidthPx = 1000,
            viewportHeightPx = 2000,
            panXPx = 0f,
            panYPx = 0f,
        )
        assertEquals(0f, tx, 0.001f)
        assertEquals(0f, ty, 0.001f)
    }

    @Test fun annotationCameraLetterboxesALandscapePageInATallerViewport() {
        // A raster page narrower than the viewport (letterboxed at rest, zoom 1x, no pan): the page is
        // centered, so its own left edge sits half the leftover width in from the viewport's own edge.
        val (tx, ty) = PagedPdfLayout.annotationCameraTranslate(
            zoom = 1f,
            rasterWidthPx = 600,
            rasterHeightPx = 800,
            viewportWidthPx = 1000,
            viewportHeightPx = 800,
            panXPx = 0f,
            panYPx = 0f,
        )
        assertEquals(200f, tx, 0.001f) // (1000 - 600) / 2
        assertEquals(0f, ty, 0.001f)
    }

    @Test fun annotationCameraScalesAboutTheRasterContentsOwnCenter() {
        // Zoomed 2x about the center: the raster content's own center (500, 500) must still map to the
        // viewport's center (500, 500) — only the translate needed to keep that fixed point changes.
        val (tx, ty) = PagedPdfLayout.annotationCameraTranslate(
            zoom = 2f,
            rasterWidthPx = 1000,
            rasterHeightPx = 1000,
            viewportWidthPx = 1000,
            viewportHeightPx = 1000,
            panXPx = 0f,
            panYPx = 0f,
        )
        // worldCenter (500, 500) -> screen: zoom*worldCenter + t = viewportCenter (500, 500).
        assertEquals(500f, 2f * 500f + tx, 0.001f)
        assertEquals(500f, 2f * 500f + ty, 0.001f)
    }

    @Test fun annotationCameraFoldsInUserPanOnTopOfCentering() {
        val (tx, ty) = PagedPdfLayout.annotationCameraTranslate(
            zoom = 1f,
            rasterWidthPx = 1000,
            rasterHeightPx = 1000,
            viewportWidthPx = 1000,
            viewportHeightPx = 1000,
            panXPx = 30f,
            panYPx = -20f,
        )
        assertEquals(30f, tx, 0.001f)
        assertEquals(-20f, ty, 0.001f)
    }
}
