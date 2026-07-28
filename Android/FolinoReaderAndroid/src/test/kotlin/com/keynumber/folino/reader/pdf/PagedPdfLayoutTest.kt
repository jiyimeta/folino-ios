package com.keynumber.folino.reader.pdf

import com.keynumber.folino.reader.ViewportUnderfill
import com.keynumber.folino.reader.clampAxisOffset
import com.keynumber.folino.reader.focalAdjustedOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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

    // -- panFromViewportOffset ------------------------------------------------------------------------
    // The one bridge between the shared `ReaderViewportState` (scroll-space offsets, `ViewportUnderfill
    // .CENTER` on both axes) and this surface's CENTER-anchored placement. Pairing it with the viewport's
    // OWN clamp — `clampAxisOffset`, called here exactly as `ReaderViewportState` calls it — is what makes
    // these tests cover the CENTERED-content assumption end to end rather than a formula in isolation.

    @Test fun panIsZeroWhenTheContentIsSmallerThanTheViewport() {
        // Underfilled: the clamp forces the centered offset, and the conversion turns that back into "no
        // pan", so the page is placed by its own centering layout. This is the case that keeps a
        // differently-sized neighbour centered while it peeks in during a swipe.
        val offset = clampAxisOffset(
            offset = 500f, contentPx = 800f, viewportPx = 1000f, underfill = ViewportUnderfill.CENTER,
        )
        assertEquals(
            0f,
            PagedPdfLayout.panFromViewportOffset(offset, liveContentSizePx = 800f, viewportSizePx = 1000f),
            0.001f,
        )
    }

    @Test fun panIsZeroWhenTheContentExactlyFillsTheViewport() {
        val offset = clampAxisOffset(
            offset = 500f, contentPx = 1000f, viewportPx = 1000f, underfill = ViewportUnderfill.CENTER,
        )
        assertEquals(
            0f,
            PagedPdfLayout.panFromViewportOffset(offset, liveContentSizePx = 1000f, viewportSizePx = 1000f),
            0.001f,
        )
    }

    @Test fun panRunsToHalfTheExcessAtEitherEndOfTheOffsetRange() {
        // Content 1500 in a 1000 viewport: the viewport clamps the offset to 0..500, which converts to a
        // pan of +250..-250 — the symmetric half-the-excess bound the centered layout needs.
        val atStart = clampAxisOffset(-999f, 1500f, 1000f, ViewportUnderfill.CENTER)
        val atEnd = clampAxisOffset(999f, 1500f, 1000f, ViewportUnderfill.CENTER)
        assertEquals(250f, PagedPdfLayout.panFromViewportOffset(atStart, 1500f, 1000f), 0.001f)
        assertEquals(-250f, PagedPdfLayout.panFromViewportOffset(atEnd, 1500f, 1000f), 0.001f)
    }

    @Test fun eachAxisIsBoundedIndependentlyForALetterboxedPage() {
        // A portrait page (100 x 200 pt) fit-rendered 500px wide is 1000px tall. In a 1000 (w) x 800 (h)
        // viewport, width fits exactly (no pan at all) while height overflows by 200 (pan bound 100) — the
        // two axes must clamp independently, not share one bound.
        val liveWidthPx = PagedPdfLayout.renderWidthPx(fitWidthPx = 500, scale = 1f).toFloat()
        val liveHeightPx =
            PagedPdfLayout.heightForWidthPx(liveWidthPx.toInt(), pageWidthPt = 100.0, pageHeightPt = 200.0).toFloat()
        val offsetX = clampAxisOffset(-50f, liveWidthPx, 1000f, ViewportUnderfill.CENTER)
        val offsetY = clampAxisOffset(-250f, liveHeightPx, 800f, ViewportUnderfill.CENTER)
        assertEquals(0f, PagedPdfLayout.panFromViewportOffset(offsetX, liveWidthPx, 1000f), 0.001f)
        assertEquals(100f, PagedPdfLayout.panFromViewportOffset(offsetY, liveHeightPx, 800f), 0.001f)
    }

    @Test fun theSharedFocalZoomKeepsAnOffCenterTouchPointFixed() {
        // The property the surface's own `focalAdjustedPan` used to assert, now expressed against the
        // shared viewport's `focalAdjustedOffset` plus this conversion — a page that exactly fills a 1000px
        // viewport, no prior pan, a touch 300px right of center, doubling the zoom. Holding that touch
        // point fixed means the page must end up panned by -300.
        val fitWidthPx = 1000
        val offsetBefore = clampAxisOffset(0f, fitWidthPx * 1f, 1000f, ViewportUnderfill.CENTER)
        assertEquals(0f, PagedPdfLayout.panFromViewportOffset(offsetBefore, fitWidthPx * 1f, 1000f), 0.001f)

        val offsetAfter = clampAxisOffset(
            focalAdjustedOffset(currentScroll = offsetBefore, centroid = 800f, ratio = 2f),
            contentPx = fitWidthPx * 2f,
            viewportPx = 1000f,
            underfill = ViewportUnderfill.CENTER,
        )
        assertEquals(-300f, PagedPdfLayout.panFromViewportOffset(offsetAfter, fitWidthPx * 2f, 1000f), 0.001f)
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

    // -- pxPerPageMm (Task 11 fix-report: PDF pen/eraser were ~5x too thin) ------------------------

    @Test fun pxPerPageMmMatchesTheKnownA4PortraitRatio() {
        // A4 portrait is 595 x 842 pt ~= 209.9 x 297.2mm (595pt * 25.4/72). Rendered 1000px wide:
        // 1000 / 209.9028 ~= 4.7641 px/mm.
        val result = PagedPdfLayout.pxPerPageMm(rasterWidthPx = 1000, pageWidthPt = 595.0)
        assertEquals(4.7641f, result, 0.001f)
    }

    @Test fun pxPerPageMmScalesWithRasterWidth() {
        val at1000 = PagedPdfLayout.pxPerPageMm(rasterWidthPx = 1000, pageWidthPt = 595.0)
        val at2000 = PagedPdfLayout.pxPerPageMm(rasterWidthPx = 2000, pageWidthPt = 595.0)
        assertEquals(at1000 * 2f, at2000, 0.001f)
    }

    @Test fun pxPerPageMmIsIdentityForANonPositivePageWidth() {
        assertEquals(1f, PagedPdfLayout.pxPerPageMm(rasterWidthPx = 1000, pageWidthPt = 0.0), 0.0001f)
        assertEquals(1f, PagedPdfLayout.pxPerPageMm(rasterWidthPx = 1000, pageWidthPt = -5.0), 0.0001f)
    }

    // -- worldPointForTap (Task 14: tap-to-seek) ---------------------------------------------------
    // The inverse of the camera above. It must agree with `annotationCameraTranslate` exactly, since the cursor and
    // the ink are both placed by that function — a tap that resolves through a different camera would seek to a
    // point other than the one the user is looking at.

    /** A letterboxed page at rest: world (0, 0) is the page's top-left, inset by the centering margins. */
    @Test fun worldPointForTapUndoesCenteringAtRest() {
        val world = PagedPdfLayout.worldPointForTap(
            tapXPx = 300f,
            tapYPx = 250f,
            zoom = 1f,
            rasterWidthPx = 400,
            rasterHeightPx = 566,
            viewportWidthPx = 1000,
            viewportHeightPx = 1000,
            panXPx = 0f,
            panYPx = 0f,
        )!!
        // Content is centered: its left edge is at (1000 - 400) / 2 = 300, its top at (1000 - 566) / 2 = 217.
        assertEquals(0f, world.first, 0.001f)
        assertEquals(33f, world.second, 0.001f)
    }

    /** Round trip against the forward camera, at a zoom AND a pan — the case a hand-rolled inverse gets wrong. */
    @Test fun worldPointForTapRoundTripsTheForwardCamera() {
        val zoom = 2.5f
        val (tx, ty) = PagedPdfLayout.annotationCameraTranslate(
            zoom = zoom,
            rasterWidthPx = 700,
            rasterHeightPx = 990,
            viewportWidthPx = 1080,
            viewportHeightPx = 2100,
            panXPx = -140f,
            panYPx = 260f,
        )
        val worldX = 321f
        val worldY = 654f
        val world = PagedPdfLayout.worldPointForTap(
            tapXPx = zoom * worldX + tx,
            tapYPx = zoom * worldY + ty,
            zoom = zoom,
            rasterWidthPx = 700,
            rasterHeightPx = 990,
            viewportWidthPx = 1080,
            viewportHeightPx = 2100,
            panXPx = -140f,
            panYPx = 260f,
        )!!
        assertEquals(worldX, world.first, 0.01f)
        assertEquals(worldY, world.second, 0.01f)
    }

    @Test fun worldPointForTapRefusesANonPositiveZoom() {
        assertNull(
            PagedPdfLayout.worldPointForTap(
                tapXPx = 0f,
                tapYPx = 0f,
                zoom = 0f,
                rasterWidthPx = 400,
                rasterHeightPx = 566,
                viewportWidthPx = 1000,
                viewportHeightPx = 1000,
                panXPx = 0f,
                panYPx = 0f,
            ),
        )
    }
}
