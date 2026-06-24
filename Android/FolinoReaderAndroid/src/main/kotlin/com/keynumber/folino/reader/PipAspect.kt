package com.keynumber.folino.reader

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Android rejects PiP aspect ratios outside roughly `[1/2.39, 2.39]`; a rejected
 * `setAspectRatio` is swallowed and the window falls back to a square. We clamp a touch inside the
 * limit (2.34) so the exact boundary is never hit.
 */
const val PIP_MAX_ASPECT = 2.34

/** Clamp a desired width/height aspect into Android's accepted PiP range. */
fun pipAspectClamped(aspect: Double): Double =
    aspect.coerceIn(1.0 / PIP_MAX_ASPECT, PIP_MAX_ASPECT)

/**
 * PiP window aspect ratio (width / height) chosen so the visible horizontal system *just fits* the
 * window, mirroring the user's intent (no vertical overflow, no broken auto-scroll).
 *
 * The horizontal Reader scales the score so the A4 width ([fitWidthMM], 210mm) fills the window
 * width; the system's on-screen height is then `systemHeightMM * windowWidth / fitWidthMM`. Setting
 * `aspect = fitWidthMM / systemHeightMM` makes that equal the window height, so the whole system
 * fits vertically. A small [slack] keeps it strictly inside so rounding never overflows (which would
 * re-enable vertical scrolling). The result is clamped to Android's accepted range.
 *
 * A thin single staff therefore yields a wide window (clamped to the max); a tall multi-staff system
 * yields a squarer/taller one — each just fitting the visible system.
 */
fun pipAspectForSystemHeight(systemHeightMM: Double, fitWidthMM: Double): Double {
    if (systemHeightMM <= 0.0 || fitWidthMM <= 0.0) return PIP_MAX_ASPECT
    val slack = 1.06
    return pipAspectClamped(fitWidthMM / (systemHeightMM * slack))
}

/** Vertical breathing room (each side) left around the system inside the PiP window. Mirrors iOS's
 *  `ScorePiPFrameRenderer.verticalPaddingPt = 16`. Tunable; confirmed by the iOS side-by-side. */
val PIP_VERTICAL_PAD: Dp = 16.dp

/**
 * Render density (pixels per layout-mm) for the PiP score, chosen so the single system's full height
 * fits the current PiP window height with [verticalPadPx] breathing room on each side. Unlike the
 * full-screen Reader (fixed device-independent [fixedPxPerMm]), PiP scales with the window so the
 * whole system stays visible at every PiP size stage — mirroring iOS, where AVKit scales a fixed
 * buffer to the window. Returns 0 for a degenerate viewport / system so callers can no-op.
 */
fun pipFitPxPerMm(
    viewportHeightPx: Int,
    verticalPadPx: Float,
    systemHeightMM: Double,
): Float {
    if (viewportHeightPx <= 0 || systemHeightMM <= 0.0) return 0f
    val usable = viewportHeightPx - 2f * verticalPadPx
    if (usable <= 0f) return 0f
    return (usable / systemHeightMM).toFloat()
}
