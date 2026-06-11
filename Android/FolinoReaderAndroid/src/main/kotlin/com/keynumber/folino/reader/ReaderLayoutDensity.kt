package com.keynumber.folino.reader

/**
 * Fixed layout density: logical dp per layout-millimetre.
 *
 * Anchored so a ~393dp-wide phone lays out ~210mm of score width — phones render as before, while
 * wider tablets reflow MORE music at the SAME staff size (matching iOS, which lays out at the real
 * viewport width instead of zooming a fixed A4 page). Tunable; confirmed by the phone/tablet
 * screenshot pass.
 */
const val LAYOUT_DP_PER_MM: Double = 393.0 / 210.0 // ≈ 1.8714

/** Smallest layout width we ever ask the engine for, so a zero/garbage viewport never degenerates. */
private const val MIN_LAYOUT_WIDTH_MM: Double = 80.0

/** Render scale (pixels per layout-mm) at the given Compose density (`Density.density` = px per dp). */
fun fixedPxPerMm(densityPxPerDp: Float): Float = (LAYOUT_DP_PER_MM * densityPxPerDp).toFloat()

/**
 * Layout width (mm) to feed the engine for a viewport [widthPx] at [densityPxPerDp].
 * Inverse of [fixedPxPerMm]: `widthMm = widthPx / pxPerMm = widthDp / LAYOUT_DP_PER_MM`.
 */
fun layoutWidthMm(widthPx: Int, densityPxPerDp: Float): Double {
    if (widthPx <= 0 || densityPxPerDp <= 0f) return MIN_LAYOUT_WIDTH_MM
    return maxOf(widthPx / fixedPxPerMm(densityPxPerDp).toDouble(), MIN_LAYOUT_WIDTH_MM)
}
