package com.keynumber.folino.reader.pdf

import kotlin.math.floor

/**
 * The ONE ceiling on how large a page may actually be RASTERIZED, read by both PDF surfaces
 * ([PdfVerticalScore] and [PagedPdfScore]) so the limit cannot drift between them.
 *
 * **Why a ceiling exists.** Both surfaces clamp the pinch to `1f..8f` and derive the render width by
 * multiplying the viewport (or fit) width straight by the settled raster scale, with nothing bounding the
 * result. On a 1080px-wide viewport at scale 8 that asks [PdfPageSource] for an 8640 x ~12200 `ARGB_8888`
 * bitmap — roughly 420MB — and [PdfVerticalScore] keeps a three-page window, so three of them. What the
 * reader actually SEES when that fails is a blank page, not a degraded one: `renderAndCache` catches the
 * `OutOfMemoryError` and returns null, but `ensureRenderJob` has already cleared the cache slot's bitmap
 * for the new width, so the page item nulls its own bitmap and draws a plain white rectangle with no
 * fallback to the previous, lower-resolution render. Well below the OOM threshold there is a second, harder
 * limit: 8640px exceeds the maximum texture size many GPUs report, and an oversized texture fails to upload
 * rather than degrading.
 *
 * **Why 4096, on the LARGER dimension.** 4096 is the conservative maximum texture size — the floor
 * OpenGL ES 3.0 guarantees, so a bitmap inside it uploads on any device folino ships to; 8192 is common but
 * not universal, and there is no cheap way to ask before rendering. The bound has to be on the larger
 * dimension because a score page is portrait: capping width alone would still let an A4 page rendered
 * 4096px wide come out 5793px tall, over the limit on the axis that hits it first. At the cap an A4
 * portrait page is 2896 x 4096 ≈ 47MB, so the vertical surface's three-page window peaks near 142MB rather
 * than 1.2GB.
 *
 * **Why this caps the raster only, not the layout.** Callers keep sizing the page box from the PDF's own
 * point size at the UNCAPPED raster width and just request fewer pixels for it; `ContentScale.Fit` then
 * upscales the smaller bitmap into that box, on top of the `graphicsLayer` that is already applying the
 * live pinch delta. So nothing derived from the layout moves — cursor projection, annotation page frames,
 * tap hit-testing, the scroll extent — and the only visible consequence is softness past the point where a
 * page's larger dimension reaches the cap (about 2.7x zoom for an A4 page on a 1080px viewport). A soft
 * page at extreme zoom is a far better outcome than a blank one.
 *
 * The plan's §10 defers the PDF memory budget to on-device tuning; this constant is the knob that pass
 * should turn, and it is deliberately the only one.
 */
internal object PdfRasterBudget {

    /** Maximum pixels along a rasterized page's LARGER dimension. See the class doc for the derivation. */
    const val MAX_RASTER_DIMENSION_PX = 4096

    /**
     * [requestedWidthPx], reduced just enough that a page of [pageWidthPt] x [pageHeightPt] rendered at the
     * returned width has neither dimension over [MAX_RASTER_DIMENSION_PX]. Returns [requestedWidthPx]
     * unchanged when it already fits — the common case at ordinary zoom, so the cap is invisible until it
     * bites.
     *
     * A non-positive [requestedWidthPx] passes through untouched: both surfaces use `0` to mean "the
     * viewport isn't measured yet" and gate on `<= 0` before requesting a bitmap, so this must not turn
     * that sentinel into a real width. A degenerate page size (either dimension `<= 0`, which
     * `PdfRenderer` should never report) falls back to bounding the width alone.
     */
    fun rasterWidthPx(requestedWidthPx: Int, pageWidthPt: Double, pageHeightPt: Double): Int {
        if (requestedWidthPx <= 0) return requestedWidthPx
        if (pageWidthPt <= 0.0 || pageHeightPt <= 0.0) {
            return requestedWidthPx.coerceAtMost(MAX_RASTER_DIMENSION_PX)
        }
        val requestedHeightPx = requestedWidthPx.toDouble() * pageHeightPt / pageWidthPt
        val larger = maxOf(requestedWidthPx.toDouble(), requestedHeightPx)
        if (larger <= MAX_RASTER_DIMENSION_PX) return requestedWidthPx
        // `floor`, not `roundToInt`: rounding up here would put the constrained dimension back over the cap
        // by a pixel, which is exactly what the cap exists to prevent.
        return floor(requestedWidthPx * (MAX_RASTER_DIMENSION_PX / larger)).toInt().coerceAtLeast(1)
    }
}
